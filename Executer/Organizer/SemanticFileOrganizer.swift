import Foundation

/// Understands file content and context, automatically moves/renames files based on project membership.
/// Only acts on Downloads and Desktop by default. Requires Trust Ratchet approval initially.
actor SemanticFileOrganizer {
    static let shared = SemanticFileOrganizer()

    private var isRunning = false
    private var pendingSuggestions: [OrganizationSuggestion] = []
    private let maxPending = 20

    struct OrganizationSuggestion: Sendable {
        let filePath: String
        let filename: String
        let classification: FileClassifier.Classification
        let timestamp: Date
    }

    // MARK: - File Event Handler (called by FileMonitor)

    /// Process a new file event from Downloads or Desktop.
    func handleNewFile(path: String, directory: String) async {
        // Only process Downloads and Desktop
        guard directory == "Downloads" || directory == "Desktop" else { return }

        let filename = (path as NSString).lastPathComponent
        guard !filename.hasPrefix(".") else { return }

        // Skip files still being written (modified in last 30s)
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 30 { return }

        let projects = await ProjectMindMap.shared.activeProjects()
        let classification = await FileClassifier.classify(filePath: path, projects: projects)

        guard classification.confidence >= 0.5,
              let suggestedPath = classification.suggestedPath else { return }

        let suggestion = OrganizationSuggestion(
            filePath: path,
            filename: filename,
            classification: classification,
            timestamp: Date()
        )

        // Check trust level to decide: auto-move or queue for approval
        let canAutoApprove = TrustRatchet.shouldAutoApprove(
            capability: "file_organize",
            domain: classification.projectName ?? "unknown"
        )

        if canAutoApprove {
            await executeMove(from: path, to: suggestedPath, suggestion: suggestion)
        } else {
            // Queue as suggestion for morning console or coworker agent
            if pendingSuggestions.count < maxPending {
                pendingSuggestions.append(suggestion)
                print("[FileOrganizer] Queued suggestion: \(filename) → \(classification.projectName ?? "?")")
            }
        }
    }

    // MARK: - Execute

    private func executeMove(from sourcePath: String, to destPath: String, suggestion: OrganizationSuggestion) async {
        let fm = FileManager.default

        // Safety: don't overwrite existing files
        guard !fm.fileExists(atPath: destPath) else {
            print("[FileOrganizer] Skipped: destination exists \(destPath)")
            return
        }

        // Ensure destination directory exists
        let destDir = (destPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        do {
            try fm.moveItem(atPath: sourcePath, toPath: destPath)
            print("[FileOrganizer] Moved: \(suggestion.filename) → \(destPath)")

            // Update project mind map
            if let projectId = suggestion.classification.projectId {
                await ProjectMindMap.shared.linkFile(destPath, toProject: projectId)
            }

            // Record success for trust ratchet
            TrustRatchet.recordSuccess(
                capability: "file_organize",
                domain: suggestion.classification.projectName ?? "unknown"
            )
        } catch {
            print("[FileOrganizer] Move failed: \(error)")
            TrustRatchet.recordFailure(
                capability: "file_organize",
                domain: suggestion.classification.projectName ?? "unknown"
            )
        }
    }

    // MARK: - Queries

    func getSuggestions() -> [OrganizationSuggestion] { pendingSuggestions }

    func approveSuggestion(at index: Int) async -> Bool {
        guard index < pendingSuggestions.count else { return false }
        let suggestion = pendingSuggestions.remove(at: index)
        if let dest = suggestion.classification.suggestedPath {
            await executeMove(from: suggestion.filePath, to: dest, suggestion: suggestion)
            return true
        }
        return false
    }

    func dismissSuggestion(at index: Int) {
        guard index < pendingSuggestions.count else { return }
        let suggestion = pendingSuggestions.remove(at: index)
        TrustRatchet.recordFailure(
            capability: "file_organize",
            domain: suggestion.classification.projectName ?? "unknown"
        )
    }

    func clearExpiredSuggestions() {
        let cutoff = Date().addingTimeInterval(-86400) // 24h expiry
        pendingSuggestions.removeAll { $0.timestamp < cutoff }
    }
}

// MARK: - Tools

struct OrganizeFileTool: ToolDefinition {
    let name = "organize_file"
    let description = "Classify a file and move it to the appropriate project folder based on its content and name."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "file_path": JSONSchema.string(description: "Absolute path to the file to organize"),
        ], required: ["file_path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("file_path", from: args)

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return "File not found: \(path)" }

        let projects = await ProjectMindMap.shared.activeProjects()
        let classification = await FileClassifier.classify(filePath: path, projects: projects)

        if let dest = classification.suggestedPath, classification.confidence >= 0.5 {
            guard !fm.fileExists(atPath: dest) else {
                return "Would move to \(dest) but file already exists there."
            }
            let destDir = (dest as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            try fm.moveItem(atPath: path, toPath: dest)

            if let projectId = classification.projectId {
                await ProjectMindMap.shared.linkFile(dest, toProject: projectId)
            }

            return "Moved to \(dest) (project: \(classification.projectName ?? "unknown"), confidence: \(String(format: "%.0f%%", classification.confidence * 100)))"
        } else {
            return "Could not classify file. \(classification.reason) (confidence: \(String(format: "%.0f%%", classification.confidence * 100)))"
        }
    }
}

struct GetOrganizationSuggestionsTool: ToolDefinition {
    let name = "get_organization_suggestions"
    let description = "Get pending file organization suggestions that need approval."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:], required: [])
    }

    func execute(arguments: String) async throws -> String {
        let suggestions = await SemanticFileOrganizer.shared.getSuggestions()
        guard !suggestions.isEmpty else { return "No pending file organization suggestions." }

        var result = "Pending suggestions (\(suggestions.count)):\n"
        for (i, s) in suggestions.enumerated() {
            result += "\(i + 1). **\(s.filename)** → \(s.classification.projectName ?? "unknown")\n"
            result += "   From: \(s.filePath)\n"
            result += "   To: \(s.classification.suggestedPath ?? "?")\n"
            result += "   Confidence: \(String(format: "%.0f%%", s.classification.confidence * 100)) — \(s.classification.reason)\n"
        }
        return result
    }
}
