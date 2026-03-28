import Foundation

/// Ranks goals and sessions by urgency, frequency, and recency.
/// Determines what gets injected into the LLM prompt.
enum PriorityRanker {

    /// Get the top goals to inject into the system prompt.
    /// Returns at most 3 goals formatted for LLM context.
    static func topGoalsForPrompt() -> String {
        let goals = GoalTracker.shared.topGoals(limit: 3)
        guard !goals.isEmpty else { return "" }

        var lines = ["## Active Goals:"]
        for goal in goals {
            lines.append(goal.summary())
        }

        // Add urgency alerts
        let alerts = DeadlineAwareness.generateAlerts()
        if !alerts.isEmpty {
            lines.append("\n## Deadline Alerts:")
            for alert in alerts.prefix(3) {
                lines.append("- \(alert)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Get the current work motivation summary.
    /// Combines current session, goals, and intent into a single context string.
    static func motivationContext(for session: WorkSession?) -> String {
        guard let session = session else { return "" }

        let goal = GoalTracker.shared.relevantGoal(for: session)
        let intent = IntentInferenceEngine.inferIntent(for: session, goal: goal)

        return IntentInferenceEngine.motivationSummary(
            session: session,
            goal: goal,
            intent: intent
        )
    }
}
