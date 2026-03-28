import Foundation

/// Generates a daily work plan from goals, calendar, and routines.
enum DayPlanner {

    /// Generate today's work plan.
    static func generatePlan() -> String {
        var plan: [String] = ["## Today's Work Plan"]

        // 1. Calendar events
        if let nextEvent = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 12) {
            plan.append("\n### Upcoming: \(nextEvent.title ?? "Event")")
        }

        // 2. Active goals
        let goals = GoalTracker.shared.topGoals(limit: 3)
        if !goals.isEmpty {
            plan.append("\n### Priority Goals:")
            for goal in goals {
                plan.append(goal.summary())
            }
        }

        // 3. Routines
        let routines = PredictionEngine.shared.getRoutines()
            .filter { $0.confidence > 0.6 }
            .prefix(5)
        if !routines.isEmpty {
            plan.append("\n### Usual Routines:")
            for routine in routines {
                plan.append("- \(routine.description)")
            }
        }

        return plan.joined(separator: "\n")
    }
}
