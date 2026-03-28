import Foundation

/// Detects urgency by combining deadline proximity with session intensity.
/// Generates urgency alerts for goals that need attention.
enum DeadlineAwareness {

    /// Urgency level for a goal.
    enum UrgencyLevel: String {
        case critical   // < 2 hours until deadline
        case high       // < 8 hours
        case medium     // < 24 hours
        case low        // < 72 hours
        case none       // No deadline or > 72 hours
    }

    /// Assess urgency of a goal.
    static func assessUrgency(_ goal: Goal) -> UrgencyLevel {
        guard let deadline = goal.deadline else { return .none }

        let hoursRemaining = deadline.timeIntervalSince(Date()) / 3600

        if hoursRemaining <= 0 { return .critical }  // Past due
        if hoursRemaining <= 2 { return .critical }
        if hoursRemaining <= 8 { return .high }
        if hoursRemaining <= 24 { return .medium }
        if hoursRemaining <= 72 { return .low }
        return .none
    }

    /// Generate urgency alerts for the current goals.
    /// Returns alerts only for goals with medium+ urgency.
    static func generateAlerts() -> [String] {
        let goals = GoalTracker.shared.topGoals(limit: 10)
        var alerts: [String] = []

        for goal in goals {
            let urgency = assessUrgency(goal)
            guard urgency != .none else { continue }

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            var alert = ""
            switch urgency {
            case .critical:
                if let deadline = goal.deadline, deadline < Date() {
                    alert = "OVERDUE: \(goal.topic) — deadline was \(formatter.localizedString(for: deadline, relativeTo: Date()))"
                } else {
                    alert = "URGENT: \(goal.topic) — deadline \(formatter.localizedString(for: goal.deadline!, relativeTo: Date()))"
                }
            case .high:
                alert = "HIGH: \(goal.topic) — due \(formatter.localizedString(for: goal.deadline!, relativeTo: Date()))"
                if let source = goal.deadlineSource { alert += " (\(source))" }
            case .medium:
                alert = "\(goal.topic) — due \(formatter.localizedString(for: goal.deadline!, relativeTo: Date()))"
            case .low:
                alert = "\(goal.topic) — due \(formatter.localizedString(for: goal.deadline!, relativeTo: Date()))"
            case .none:
                break
            }

            if !alert.isEmpty {
                alerts.append(alert)
            }
        }

        return alerts
    }
}
