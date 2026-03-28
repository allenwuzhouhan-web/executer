import Foundation

/// Infers WHY the user is doing something by combining:
/// - Session context (what they're working on)
/// - Calendar correlation (upcoming events)
/// - Goal context (multi-day objectives)
/// - Action patterns (what type of work)
enum IntentInferenceEngine {

    /// Infer the intent behind a work session.
    static func inferIntent(for session: WorkSession, goal: Goal? = nil) -> IntentAnnotation {
        // 1. Check calendar correlation
        if let (event, confidence) = CalendarCorrelator.shared.correlate(session: session) {
            return IntentAnnotation(
                sessionId: session.id,
                goalId: goal?.id,
                intentType: .preparing,
                confidence: confidence,
                calendarEventTitle: event.title,
                description: "Preparing for \(event.title ?? "upcoming event")"
            )
        }

        // 2. Infer from session category and content
        let intentType = inferTypeFromContent(session)

        // 3. Build description
        var description = "\(intentType.rawValue.capitalized)"
        if let goal = goal {
            description += " for \(goal.topic)"
        } else if !session.topics.isEmpty {
            description += ": \(session.topics.sorted().prefix(3).joined(separator: ", "))"
        }

        return IntentAnnotation(
            sessionId: session.id,
            goalId: goal?.id,
            intentType: intentType,
            confidence: 0.5,
            calendarEventTitle: nil,
            description: description
        )
    }

    /// Infer intent type from session content and observations.
    private static func inferTypeFromContent(_ session: WorkSession) -> IntentAnnotation.IntentType {
        // Check observation categories
        let categories = session.observations.map(\.category)
        let categoryFreq = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
        let dominant = categoryFreq.max(by: { $0.value < $1.value })?.key ?? .other

        switch dominant {
        case .communication:
            return .communicating
        case .research, .browsing:
            return .researching
        case .coding:
            // Check if debugging (look for error-related keywords)
            let hasErrorKeywords = session.topics.contains(where: {
                $0.lowercased().contains("error") || $0.lowercased().contains("bug") || $0.lowercased().contains("fix")
            })
            return hasErrorKeywords ? .debugging : .creating
        case .writing, .design:
            return .creating
        case .dataAnalysis:
            return .researching
        default:
            return .routine
        }
    }

    /// Generate a human-readable motivation summary for prompt injection.
    static func motivationSummary(session: WorkSession, goal: Goal?, intent: IntentAnnotation) -> String {
        var parts: [String] = []

        // What
        parts.append("Currently \(intent.intentType.rawValue)")

        // Why (calendar-driven)
        if let eventTitle = intent.calendarEventTitle {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            // Find the event time from calendar
            if let event = CalendarCorrelator.shared.correlate(session: session) {
                let relative = formatter.localizedString(for: event.event.startDate, relativeTo: Date())
                parts.append("for \"\(eventTitle)\" \(relative)")
            } else {
                parts.append("for \"\(eventTitle)\"")
            }
        }

        // Goal context
        if let goal = goal {
            parts.append("(part of \(goal.topic), \(goal.totalTimeFormatted) invested over \(goal.sessionCount) sessions)")
        }

        return parts.joined(separator: " ")
    }
}
