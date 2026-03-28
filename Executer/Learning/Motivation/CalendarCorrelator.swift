import Foundation
import EventKit

/// Correlates work sessions with calendar events to infer motivation.
/// Example: User is in Keynote → calendar has "Board Meeting" in 2 hours → infers "preparing presentation for board meeting"
final class CalendarCorrelator {
    static let shared = CalendarCorrelator()

    private lazy var eventStore = EKEventStore()

    private init() {}

    /// Find calendar events that might explain why the user is doing this session.
    /// Looks ahead up to 24 hours for matching events.
    func correlate(session: WorkSession) -> (event: EKEvent, confidence: Double)? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let now = Date()
        let lookAhead = now.addingTimeInterval(24 * 3600) // Next 24 hours

        let predicate = eventStore.predicateForEvents(withStart: now, end: lookAhead, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Score each event against the session's topics
        var bestMatch: (EKEvent, Double)?

        for event in events {
            let eventText = (event.title ?? "").lowercased() + " " + (event.notes ?? "").lowercased()
            let eventKeywords = Set(eventText.split(separator: " ").map(String.init).filter { $0.count > 2 })
            let sessionTopics = session.topics.map { $0.lowercased() }

            // Calculate keyword overlap
            var matchScore = 0.0
            for topic in sessionTopics {
                if eventKeywords.contains(topic) {
                    matchScore += 1.0
                }
                // Partial match (topic word appears in event title)
                if eventText.contains(topic) {
                    matchScore += 0.5
                }
            }

            guard matchScore > 0 else { continue }

            // Boost score for closer events (urgency)
            let hoursUntilEvent = event.startDate.timeIntervalSince(now) / 3600
            let urgencyBoost = max(0.1, 1.0 - (hoursUntilEvent / 24.0))
            let totalScore = matchScore * urgencyBoost

            if bestMatch == nil || totalScore > bestMatch!.1 {
                bestMatch = (event, min(totalScore, 1.0))
            }
        }

        return bestMatch
    }

    /// Find the next upcoming event (regardless of topic match).
    func nextUpcomingEvent(withinHours hours: Double = 4) -> EKEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let now = Date()
        let end = now.addingTimeInterval(hours * 3600)

        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    /// Extract a deadline from calendar events matching the given topics.
    func findDeadline(forTopics topics: Set<String>) -> (date: Date, eventTitle: String)? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let now = Date()
        let lookAhead = now.addingTimeInterval(30 * 24 * 3600) // Next 30 days

        let predicate = eventStore.predicateForEvents(withStart: now, end: lookAhead, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        for event in events {
            let eventText = (event.title ?? "").lowercased()
            for topic in topics {
                if eventText.contains(topic.lowercased()) {
                    return (event.startDate, event.title ?? "")
                }
            }
        }

        return nil
    }
}
