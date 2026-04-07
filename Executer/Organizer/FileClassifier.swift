import Foundation

/// Lightweight file classification: reads filename + extension + first 500 chars → project ID + suggested path.
enum FileClassifier {

    struct Classification: Sendable {
        let projectId: UUID?
        let projectName: String?
        let suggestedPath: String?
        let confidence: Double
        let reason: String
    }

    /// Classify a file against known projects using pattern matching first, LLM fallback for ambiguous cases.
    static func classify(
        filePath: String,
        projects: [ProjectNode]
    ) async -> Classification {
        let filename = (filePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        let nameWithoutExt = (filename as NSString).deletingPathExtension.lowercased()

        // Fast path: check cached patterns first
        if let cached = PatternCache.shared.lookup(filename: filename) {
            return cached
        }

        // Phase 1: Keyword matching against project names and tags
        for project in projects {
            let projectLower = project.name.lowercased()
            let tagSet = Set(project.tags.map { $0.lowercased() })

            // Check if filename contains project name or tag
            if nameWithoutExt.contains(projectLower) ||
               project.tags.contains(where: { nameWithoutExt.contains($0.lowercased()) }) {
                let result = Classification(
                    projectId: project.id,
                    projectName: project.name,
                    suggestedPath: project.rootPath.map { $0 + "/" + filename },
                    confidence: 0.8,
                    reason: "Filename matches project '\(project.name)'"
                )
                PatternCache.shared.store(filename: filename, classification: result)
                return result
            }

            // Check extension patterns in existing project files
            let projectExts = Set(project.files.map { ($0 as NSString).pathExtension.lowercased() })
            if projectExts.contains(ext) && project.files.count > 5 {
                // Project has many files of this type — weak signal
                let result = Classification(
                    projectId: project.id,
                    projectName: project.name,
                    suggestedPath: project.rootPath.map { $0 + "/" + filename },
                    confidence: 0.3,
                    reason: "Extension .\(ext) common in project '\(project.name)'"
                )
                return result
            }
        }

        // Phase 2: Content-based classification via LLM for ambiguous files
        if ["pdf", "docx", "txt", "md", "csv"].contains(ext) {
            return await classifyWithLLM(filePath: filePath, filename: filename, projects: projects)
        }

        return Classification(projectId: nil, projectName: nil, suggestedPath: nil,
                            confidence: 0.0, reason: "No matching project found")
    }

    private static func classifyWithLLM(
        filePath: String,
        filename: String,
        projects: [ProjectNode]
    ) async -> Classification {
        // Read first 500 chars of the file
        let preview: String
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "file_preview",
                arguments: "{\"path\": \"\(filePath)\"}"
            )
            preview = String(content.prefix(500))
        } catch {
            preview = filename
        }

        let projectList = projects.map { "\($0.name) [\($0.tags.joined(separator: ","))]" }.joined(separator: "\n")

        let prompt = """
        Classify this file into one of the user's projects. Reply with ONLY the project name, or "NONE" if no match.

        File: \(filename)
        Preview: \(preview)

        Projects:
        \(projectList)
        """

        do {
            let response = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 50
            ).text ?? ""

            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.uppercased() == "NONE" {
                return Classification(projectId: nil, projectName: nil, suggestedPath: nil,
                                    confidence: 0.1, reason: "LLM: no match")
            }

            if let match = projects.first(where: { $0.name.lowercased() == cleaned.lowercased() }) {
                let result = Classification(
                    projectId: match.id,
                    projectName: match.name,
                    suggestedPath: match.rootPath.map { $0 + "/" + filename },
                    confidence: 0.7,
                    reason: "LLM classified as '\(match.name)'"
                )
                PatternCache.shared.store(filename: filename, classification: result)
                return result
            }
        } catch {
            print("[FileClassifier] LLM classification failed: \(error)")
        }

        return Classification(projectId: nil, projectName: nil, suggestedPath: nil,
                            confidence: 0.0, reason: "Classification failed")
    }
}

/// Caches (filename_pattern → classification) to avoid repeated LLM calls.
final class PatternCache {
    static let shared = PatternCache()

    private var cache: [String: FileClassifier.Classification] = [:]
    private let lock = NSLock()
    private let maxEntries = 500

    func lookup(filename: String) -> FileClassifier.Classification? {
        let key = patternKey(filename)
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func store(filename: String, classification: FileClassifier.Classification) {
        let key = patternKey(filename)
        lock.lock()
        if cache.count >= maxEntries {
            // Evict oldest quarter
            let keys = Array(cache.keys)
            for k in keys.prefix(maxEntries / 4) { cache.removeValue(forKey: k) }
        }
        cache[key] = classification
        lock.unlock()
    }

    /// Pattern key: extension + first word of filename → groups similar files.
    private func patternKey(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name = (filename as NSString).deletingPathExtension.lowercased()
        let firstWord = name.components(separatedBy: CharacterSet.alphanumerics.inverted).first ?? name
        return "\(ext):\(firstWord)"
    }
}
