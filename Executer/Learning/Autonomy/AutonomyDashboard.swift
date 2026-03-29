import Foundation

/// Status dashboard: what AI has learned, confidence levels, recent actions.
enum AutonomyDashboard {

    /// Generate a full status report.
    static func statusReport() -> String {
        var lines = ["## Autonomy Dashboard"]
        lines.append("NOTE: All data below is from REAL observations. If a section says 0 or empty, report it as-is. Do NOT invent or estimate any numbers.")

        // Learning stats
        let apps = LearningDatabase.shared.allAppNames()
        lines.append("\n### Learning Stats:")
        lines.append("- Apps observed: \(apps.count)")
        lines.append("- Total patterns: \(apps.reduce(0) { $0 + $1.patternCount })")
        if apps.isEmpty {
            lines.append("- No apps observed yet. Learning is still collecting data.")
        }

        // Goals
        let goals = GoalTracker.shared.topGoals(limit: 5)
        lines.append("\n### Active Goals: \(goals.count)")
        for goal in goals {
            lines.append(goal.summary())
        }

        // Templates
        let templates = TemplateLibrary.shared.all()
        lines.append("\n### Workflow Templates: \(templates.count)")
        for t in templates.prefix(5) {
            lines.append("- \(t.name) (executed \(t.timesExecuted)x, \(String(format: "%.0f%%", t.successRate * 100)) success)")
        }

        // Execution log
        let execRate = ExecutionLogger.shared.successRate()
        lines.append("\n### Execution Success Rate: \(String(format: "%.1f%%", execRate * 100))")

        // Prediction accuracy
        lines.append("\n### Prediction Accuracy:")
        lines.append(PredictionEvaluator.shared.summary())

        // Suggestion acceptance
        lines.append("\n### Suggestion Acceptance:")
        lines.append(SuggestionFeedback.summary())

        return lines.joined(separator: "\n")
    }
}
