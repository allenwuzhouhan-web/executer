import Foundation
import EventKit
import AppKit

/// Detects meeting state and provides calendar-aware context for synthesis.
///
/// Capabilities:
/// 1. Detects whether the user is currently in a meeting (meeting app active + calendar event now)
/// 2. Provides meeting context for enriching cross-app synthesis
/// 3. Gathers comprehensive meeting prep data from all sources
/// 4. Gathers post-meeting data for synthesis
enum MeetingIntelligence {

    // MARK: - Shared Event Store

    private static let eventStore = EKEventStore()

    // MARK: - Meeting App Detection

    private static let meetingApps: Set<String> = [
        "Zoom", "zoom.us", "FaceTime", "Microsoft Teams", "Webex",
        "Slack", "Discord", "Lark", "Feishu", "DingTalk",
    ]

    private static let meetingBrowserPatterns: [String] = [
        "meet.google.com", "Google Meet", "Zoom Meeting",
        "Microsoft Teams", "teams.microsoft.com",
    ]

    // MARK: - Meeting State

    struct MeetingState: Sendable {
        let isInMeeting: Bool
        let currentEvent: CalendarEventSnapshot?
        let meetingApp: String?
        let minutesElapsed: Int
        let phase: MeetingPhase

        enum MeetingPhase: String, Sendable {
            case none
            case upcoming       // Within 15 min
            case active         // Currently in meeting
            case justEnded      // Meeting app active but no calendar event
        }
    }

    /// Sendable snapshot of a calendar event (EKEvent is not Sendable).
    struct CalendarEventSnapshot: Sendable {
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
        let attendeeCount: Int
        let calendarName: String?

        init(from event: EKEvent) {
            self.title = event.title ?? "Untitled"
            self.startDate = event.startDate
            self.endDate = event.endDate
            self.location = event.location
            self.notes = event.notes
            self.attendeeCount = event.attendees?.count ?? 0
            self.calendarName = event.calendar?.title
        }

        var durationMinutes: Int { Int(endDate.timeIntervalSince(startDate) / 60) }

        var keywords: Set<String> {
            let text = (title + " " + (notes ?? "")).lowercased()
            return Set(text.split(separator: " ").map(String.init).filter { $0.count > 2 })
        }
    }

    // MARK: - State Detection

    /// Determine the current meeting state by checking calendar + active apps.
    /// Called from synthesis loop — lightweight, no LLM.
    static func currentState(currentApp: String, windowTitle: String) -> MeetingState {
        let now = Date()

        // 1. Check meeting app
        var activeMeetingApp: String?
        if meetingApps.contains(currentApp) {
            activeMeetingApp = currentApp
        } else if ["Safari", "Google Chrome", "Firefox", "Arc"].contains(currentApp) {
            let lower = windowTitle.lowercased()
            if meetingBrowserPatterns.contains(where: { lower.contains($0.lowercased()) }) {
                activeMeetingApp = "\(currentApp) (web meeting)"
            }
        }

        // 2. Check calendar
        let currentEvent = findCurrentEvent(at: now)
        let upcomingEvent = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 0.25)

        // 3. Determine phase
        if let event = currentEvent {
            let snapshot = CalendarEventSnapshot(from: event)
            let elapsed = max(0, Int(now.timeIntervalSince(event.startDate) / 60))
            return MeetingState(
                isInMeeting: true,
                currentEvent: snapshot,
                meetingApp: activeMeetingApp,
                minutesElapsed: elapsed,
                phase: .active
            )
        }

        if let upcoming = upcomingEvent {
            let minutesUntil = Int(upcoming.startDate.timeIntervalSince(now) / 60)
            if minutesUntil <= 15 {
                return MeetingState(
                    isInMeeting: false,
                    currentEvent: CalendarEventSnapshot(from: upcoming),
                    meetingApp: nil,
                    minutesElapsed: 0,
                    phase: .upcoming
                )
            }
        }

        if activeMeetingApp != nil {
            return MeetingState(
                isInMeeting: false,
                currentEvent: nil,
                meetingApp: activeMeetingApp,
                minutesElapsed: 0,
                phase: .justEnded
            )
        }

        return MeetingState(isInMeeting: false, currentEvent: nil, meetingApp: nil, minutesElapsed: 0, phase: .none)
    }

    private static func findCurrentEvent(at date: Date) -> EKEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let predicate = eventStore.predicateForEvents(
            withStart: date.addingTimeInterval(-3600),
            end: date.addingTimeInterval(300),
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate <= date && $0.endDate > date }
            .sorted { $0.startDate > $1.startDate }
            .first
    }

    // MARK: - Meeting Prep (Comprehensive Context Gathering)

    /// Gather comprehensive context for an upcoming meeting from all available sources.
    static func gatherPrepContext(for event: CalendarEventSnapshot) async -> String {
        let eventKeywords = event.keywords
        var lines: [String] = []

        lines.append("## Meeting Prep: \(event.title)")

        // Time + logistics
        let tf = DateFormatter(); tf.timeStyle = .short
        lines.append("**When:** \(tf.string(from: event.startDate)) — \(tf.string(from: event.endDate)) (\(event.durationMinutes) min)")
        if let loc = event.location, !loc.isEmpty { lines.append("**Where:** \(loc)") }
        if event.attendeeCount > 0 { lines.append("**Attendees:** \(event.attendeeCount) people") }
        if let notes = event.notes, !notes.isEmpty {
            lines.append("**Notes:** \(String(notes.prefix(300)))")
        }

        // 1. Related goals + deadline alerts
        let goals = GoalTracker.shared.topGoals(limit: 10)
        let relevantGoals = goals.filter { goal in
            eventKeywords.contains(where: { goal.topic.lowercased().contains($0) }) ||
            goal.relatedTopics.contains(where: { eventKeywords.contains($0.lowercased()) })
        }
        if !relevantGoals.isEmpty {
            lines.append("\n### Related Goals")
            for goal in relevantGoals {
                let urgency = DeadlineAwareness.assessUrgency(goal)
                let urgencyTag = urgency != .none ? " [\(urgency.rawValue)]" : ""
                lines.append("- **\(goal.topic)**\(urgencyTag) (priority: \(String(format: "%.0f%%", goal.priority * 100))): \(goal.description)")
            }
        }

        // 2. Recent sessions with matching topics
        let sessions = SessionDetector.shared.todaysSessions()
        let relevantSessions = sessions.filter { session in
            !session.topics.intersection(eventKeywords).isEmpty ||
            session.title.lowercased().split(separator: " ")
                .contains(where: { eventKeywords.contains(String($0)) })
        }
        if !relevantSessions.isEmpty {
            lines.append("\n### Recent Related Work")
            for s in relevantSessions.prefix(5) {
                lines.append("- \(s.title) (\(s.durationFormatted), apps: \(s.apps.joined(separator: ", ")))")
            }
        }

        // 3. Recent thoughts matching meeting topic
        let thoughts = ThoughtDatabase.shared.recentThoughts(limit: 30)
        let relevantThoughts = thoughts.filter { t in
            let text = ((t.windowTitle ?? "") + " " + t.textContent).lowercased()
            return eventKeywords.contains(where: { text.contains($0) })
        }
        if !relevantThoughts.isEmpty {
            lines.append("\n### Recent Screen Context")
            for t in relevantThoughts.prefix(5) {
                lines.append("- [\(t.appName)] \(String(t.textContent.prefix(150)))")
            }
        }

        // 4. Browser trail related to meeting
        let trail = await MainActor.run { BrowserTrailStore.shared.currentTrail }
        let relevantTrail = trail.filter { entry in
            let text = (entry.title + " " + entry.summary).lowercased()
            return eventKeywords.contains(where: { text.contains($0) })
        }
        if !relevantTrail.isEmpty {
            lines.append("\n### Related Research")
            for t in relevantTrail.prefix(5) {
                lines.append("- **\(t.title)**: \(String(t.summary.prefix(150)))")
            }
        }

        // 5. Active cross-app insights
        let crossAppContext = CrossAppSynthesizer.cachedPromptSection
        if !crossAppContext.isEmpty {
            lines.append("\n### Active Cross-App Context")
            lines.append(crossAppContext)
        }

        if relevantGoals.isEmpty && relevantSessions.isEmpty && relevantThoughts.isEmpty && relevantTrail.isEmpty {
            lines.append("\nNo prior work context found for this meeting topic.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Context for Synthesis Enrichment

    /// Returns a compact calendar context string for enriching synthesis prompts.
    /// Injected into cross-app fusion when a meeting is upcoming or active.
    static func calendarContextForSynthesis() -> String? {
        let state = currentState(
            currentApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            windowTitle: ""
        )

        switch state.phase {
        case .none:
            return nil
        case .upcoming:
            guard let event = state.currentEvent else { return nil }
            let minutesUntil = max(1, Int(event.startDate.timeIntervalSinceNow / 60))
            return "MEETING CONTEXT: '\(event.title)' starts in \(minutesUntil) min. Activities may be prep for this meeting."
        case .active:
            guard let event = state.currentEvent else { return nil }
            return "MEETING CONTEXT: User is currently in '\(event.title)' (\(state.minutesElapsed) min elapsed, via \(state.meetingApp ?? "calendar")). Activities are during this meeting."
        case .justEnded:
            return "MEETING CONTEXT: A meeting just ended. Activities may be post-meeting follow-up (action items, notes)."
        }
    }

    // MARK: - Post-Meeting Data

    /// Gather data about what happened during a meeting for post-meeting synthesis.
    static func gatherPostMeetingData(event: CalendarEventSnapshot) -> String {
        let start = event.startDate
        let end = min(event.endDate, Date())
        let duration = Int(end.timeIntervalSince(start) / 60)

        let allObs = AttentionTracker.shared.windowedObservations(windowMinutes: max(Double(duration), 30))
        let meetingObs = allObs.filter { $0.observation.timestamp >= start && $0.observation.timestamp <= end }
        let appsUsed = Array(Set(meetingObs.map(\.observation.appName)).sorted())

        let thoughts = ThoughtDatabase.shared.recentThoughts(limit: 50)
        let meetingThoughts = thoughts.filter { $0.timestamp >= start && $0.timestamp <= end }

        var lines = ["## Post-Meeting Summary: \(event.title)"]
        lines.append("**Duration:** \(duration) min")

        if !appsUsed.isEmpty {
            lines.append("**Apps used during meeting:** \(appsUsed.joined(separator: ", "))")
        }

        if !meetingThoughts.isEmpty {
            lines.append("\n### Activity During Meeting")
            for t in meetingThoughts.prefix(10) {
                lines.append("- [\(t.appName)] \(String(t.textContent.prefix(200)))")
            }
        }

        if appsUsed.isEmpty && meetingThoughts.isEmpty {
            lines.append("\nNo tracked activity during this meeting window.")
        }

        return lines.joined(separator: "\n")
    }
}
