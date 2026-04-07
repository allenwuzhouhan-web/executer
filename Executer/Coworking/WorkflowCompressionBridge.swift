import Foundation

/// Bridges the Learning system (pattern detection) to the Coworking system (user suggestions).
/// Patterns that meet the threshold are queued here; the CoworkingSuggestionPipeline consumes them
/// as `.workflowAutomation` suggestions. On acceptance, the pattern is compiled into a real skill.
actor WorkflowCompressionBridge {
    static let shared = WorkflowCompressionBridge()

    /// Candidates ready to be surfaced as suggestions, ordered by frequency.
    private var candidates: [WorkflowPattern] = []

    /// Pattern IDs that have been shown to the user (avoid re-showing in same session).
    private var suggestedPatternIds: Set<UUID> = []

    /// Pattern IDs the user explicitly dismissed (persisted, never re-suggest).
    private var dismissedPatternIds: Set<UUID> = []

    /// All patterns currently queued, keyed by ID for fast lookup on accept/dismiss.
    private var patternIndex: [UUID: WorkflowPattern] = [:]

    private let stateFileURL: URL = {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workflow_compression_state.json")
    }()

    private init() {
        loadState()
    }

    // MARK: - Enqueue (called by LearningManager)

    /// Queue high-frequency patterns as candidates for workflow compression suggestions.
    func enqueue(_ patterns: [WorkflowPattern]) {
        let cutoff = Date().addingTimeInterval(-48 * 3600) // Must be seen within 48h
        let eligible = patterns.filter { pattern in
            pattern.frequency >= 5
            && pattern.actions.count >= 3
            && pattern.lastSeen > cutoff
            && !dismissedPatternIds.contains(pattern.id)
            && !suggestedPatternIds.contains(pattern.id)
        }

        for pattern in eligible {
            if patternIndex[pattern.id] == nil {
                candidates.append(pattern)
                patternIndex[pattern.id] = pattern
            }
        }

        // Keep sorted by frequency (highest first)
        candidates.sort { $0.frequency > $1.frequency }
    }

    // MARK: - Consume (called by CoworkingSuggestionPipeline)

    /// Returns the best candidate pattern for a workflow compression suggestion, if any.
    /// Marks it as suggested so it won't be returned again this session.
    func nextCandidate() -> WorkflowPattern? {
        guard let pattern = candidates.first else { return nil }
        candidates.removeFirst()
        suggestedPatternIds.insert(pattern.id)
        persistState()
        return pattern
    }

    // MARK: - User Actions

    /// User accepted: compile pattern into a skill and template.
    func acceptPattern(_ patternId: UUID) {
        guard let pattern = patternIndex[patternId] else { return }

        // Compile into executable template
        guard let template = WorkflowCompiler.compile(pattern) else {
            print("[WorkflowCompression] Failed to compile pattern: \(pattern.name)")
            return
        }

        // Build skill name (same convention as old autoCompilePatterns)
        let appSlug = pattern.appName.lowercased().replacingOccurrences(of: " ", with: "_")
        let nameSlug = pattern.name.lowercased().prefix(30).replacingOccurrences(of: " ", with: "_")
        let skillName = "auto_\(appSlug)_\(nameSlug)"

        let steps = template.steps.map { $0.description }
        let skill = SkillsManager.Skill(
            name: skillName,
            description: "Auto-learned: \(pattern.name) (observed \(pattern.frequency)x)",
            exampleTriggers: [pattern.name.lowercased(), "\(pattern.appName.lowercased()) \(pattern.name.lowercased())"],
            steps: steps,
            verificationStatus: "verified"
        )

        SkillsManager.shared.addSkill(skill)
        TemplateLibrary.shared.save(template)

        // Clean up
        patternIndex.removeValue(forKey: patternId)
        persistState()
        print("[WorkflowCompression] Created skill: \(skillName) (\(pattern.frequency)x, \(steps.count) steps)")
    }

    /// User dismissed: suppress this pattern permanently.
    func dismissPattern(_ patternId: UUID) {
        dismissedPatternIds.insert(patternId)
        candidates.removeAll { $0.id == patternId }
        patternIndex.removeValue(forKey: patternId)
        persistState()
        print("[WorkflowCompression] Dismissed pattern: \(patternId)")
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var suggestedIds: [String]
        var dismissedIds: [String]
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        suggestedPatternIds = Set(state.suggestedIds.compactMap { UUID(uuidString: $0) })
        dismissedPatternIds = Set(state.dismissedIds.compactMap { UUID(uuidString: $0) })
    }

    private func persistState() {
        let state = PersistedState(
            suggestedIds: suggestedPatternIds.map(\.uuidString),
            dismissedIds: dismissedPatternIds.map(\.uuidString)
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }
}
