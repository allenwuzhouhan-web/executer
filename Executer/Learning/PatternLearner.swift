import Foundation

/// Analyzes observed user actions to extract recurring workflow patterns.
/// Identifies common sequences (e.g., "user always clicks File → New → types title in Keynote")
/// and stores them for LLM context injection.
class PatternLearner {
    static let shared = PatternLearner()
    private init() {}

    /// Minimum sequence length to consider as a pattern.
    private let minPatternLength = 3
    /// Minimum occurrences to save a pattern.
    private let minFrequency = 2
    /// Maximum patterns per app.
    private let maxPatternsPerApp = 20
    /// Maximum recent actions to keep per app.
    private let maxRecentActions = 500

    // MARK: - Pattern Extraction

    /// Analyzes the recent actions for an app and extracts recurring patterns.
    func extractPatterns(from profile: inout AppLearningProfile) {
        let actions = profile.recentActions
        guard actions.count >= minPatternLength * 2 else { return }

        // Build action signature sequences (ignoring variable content)
        let signatures = actions.map { actionSignature($0) }

        // Find repeated subsequences using sliding window (lengths 3-8)
        var patternCounts: [String: (count: Int, actions: [WorkflowPattern.PatternAction])] = [:]

        for length in minPatternLength...min(8, signatures.count / 2) {
            for i in 0...(signatures.count - length) {
                let subSeq = signatures[i..<(i + length)]
                let key = subSeq.joined(separator: "|")

                if patternCounts[key] == nil {
                    // Count occurrences of this subsequence
                    var count = 0
                    for j in 0...(signatures.count - length) {
                        if Array(signatures[j..<(j + length)]) == Array(subSeq) {
                            count += 1
                        }
                    }

                    if count >= minFrequency {
                        let patternActions = actions[i..<(i + length)].map { action in
                            WorkflowPattern.PatternAction(
                                type: action.type,
                                elementRole: action.elementRole,
                                elementTitle: action.elementTitle,
                                elementValue: action.type == .textEdit ? "" : action.elementValue // Don't store typed text
                            )
                        }
                        patternCounts[key] = (count, patternActions)
                    }
                }
            }
        }

        // Convert to WorkflowPatterns
        let now = Date()
        var newPatterns: [WorkflowPattern] = patternCounts.compactMap { (key, data) in
            let name = generatePatternName(actions: data.actions, appName: profile.appName)
            return WorkflowPattern(
                id: UUID(),
                appName: profile.appName,
                name: name,
                actions: data.actions,
                frequency: data.count,
                firstSeen: now,
                lastSeen: now
            )
        }

        // Merge with existing patterns (update frequency if similar pattern exists)
        for newPattern in newPatterns {
            if let existingIdx = profile.patterns.firstIndex(where: { isSimilarPattern($0, newPattern) }) {
                profile.patterns[existingIdx].frequency += newPattern.frequency
                profile.patterns[existingIdx].lastSeen = now
            } else {
                profile.patterns.append(newPattern)
            }
        }

        // Prune: keep top N by frequency
        profile.patterns.sort { $0.frequency > $1.frequency }
        if profile.patterns.count > maxPatternsPerApp {
            profile.patterns = Array(profile.patterns.prefix(maxPatternsPerApp))
        }

        // Prune recent actions
        if profile.recentActions.count > maxRecentActions {
            profile.recentActions = Array(profile.recentActions.suffix(maxRecentActions))
        }

        profile.lastUpdated = now
    }

    // MARK: - Helpers

    /// Creates a signature string for an action (ignoring variable content).
    private func actionSignature(_ action: UserAction) -> String {
        "\(action.type.rawValue):\(action.elementRole):\(action.elementTitle)"
    }

    /// Checks if two patterns are similar enough to merge.
    private func isSimilarPattern(_ a: WorkflowPattern, _ b: WorkflowPattern) -> Bool {
        guard a.actions.count == b.actions.count else { return false }
        var matches = 0
        for (aa, bb) in zip(a.actions, b.actions) {
            if aa.type == bb.type && aa.elementRole == bb.elementRole && aa.elementTitle == bb.elementTitle {
                matches += 1
            }
        }
        return Double(matches) / Double(a.actions.count) >= 0.8
    }

    /// Generates a human-readable name for a pattern.
    private func generatePatternName(actions: [WorkflowPattern.PatternAction], appName: String) -> String {
        // Use the most descriptive action titles
        let titles = actions.compactMap { $0.elementTitle.isEmpty ? nil : $0.elementTitle }
        if titles.isEmpty {
            return "\(appName) workflow (\(actions.count) steps)"
        }
        let key = titles.prefix(3).joined(separator: " → ")
        return "\(key) in \(appName)"
    }
}
