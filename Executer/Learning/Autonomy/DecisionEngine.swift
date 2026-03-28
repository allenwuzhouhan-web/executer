import Foundation

/// Makes routine decisions based on learned preferences.
enum DecisionEngine {

    /// Make a decision based on learned patterns.
    static func decide(context: String, options: [String]) -> (choice: String, confidence: Double, reasoning: String)? {
        guard !options.isEmpty else { return nil }

        // Simple heuristic: check if any option matches a frequent pattern
        let goals = GoalTracker.shared.topGoals(limit: 5)
        let goalTopics = goals.flatMap { $0.relatedTopics }

        for option in options {
            for topic in goalTopics {
                if option.lowercased().contains(topic.lowercased()) {
                    return (option, 0.6, "Aligns with active goal: \(topic)")
                }
            }
        }

        // Default: choose first option with low confidence
        return (options[0], 0.3, "Default choice — no strong preference detected")
    }
}
