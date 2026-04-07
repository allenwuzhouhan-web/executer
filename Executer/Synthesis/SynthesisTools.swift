import Foundation
import AppKit

/// On-demand cross-app synthesis. Returns active insights and optionally triggers a fresh pass.
struct SynthesizeActivityTool: ToolDefinition {
    let name = "synthesize_activity"
    let description = "Synthesize the user's current cross-app activity into higher-order insights. Connects what the user is doing across multiple apps (e.g., researching in Safari while drafting in Pages while chatting in Slack). Use when you need to understand the user's overarching goal across apps."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "time_window": JSONSchema.integer(description: "How many minutes back to consider (default 30, max 120)", minimum: 5, maximum: 120),
        ])
    }

    func execute(arguments: String) async throws -> String {
        // Force a real-time synthesis pass
        await CrossAppSynthesizer.shared.forceSynthesis()

        let insights = await CrossAppSynthesizer.shared.getActiveInsights()

        // Also include any deep synthesis insights from the hourly engine
        let deepInsight = await SynthesisEngine.shared.nextPendingInsight()

        if insights.isEmpty && deepInsight == nil {
            return "No cross-app activity detected yet. The synthesis engine needs observations from 2+ apps with overlapping topics to produce insights. Keep working and check back later."
        }

        var lines: [String] = []

        if !insights.isEmpty {
            lines.append("## Real-Time Cross-App Insights (\(insights.count)):")
            for insight in insights {
                lines.append("")
                lines.append("### \(insight.title)")
                lines.append("**Type:** \(insight.type.rawValue) | **Confidence:** \(String(format: "%.0f%%", insight.confidence * 100))")
                lines.append(insight.summary)
                lines.append("**Apps:** \(insight.connectedApps.joined(separator: ", "))")
                if !insight.connectedTopics.isEmpty {
                    lines.append("**Topics:** \(insight.connectedTopics.prefix(8).joined(separator: ", "))")
                }
                if insight.actionability != .informational {
                    lines.append("**Action:** \(insight.actionability.rawValue)")
                }
            }
        }

        if let deep = deepInsight {
            lines.append("")
            lines.append("## Deep Synthesis Insight:")
            lines.append("### \(deep.headline)")
            lines.append(deep.explanation)
            lines.append("**Domains:** \(deep.domains.joined(separator: ", "))")
            if let action = deep.actionSuggestion {
                lines.append("**Suggested action:** \(action)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Research aggregation — correlates browser trails + app observations on a topic.
struct SynthesizeResearchTool: ToolDefinition {
    let name = "synthesize_research"
    let description = "Aggregate the user's research activity across browser tabs and apps into a synthesis. Use when the user has been researching a topic across multiple websites and you want to summarize their findings."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "topic": JSONSchema.string(description: "The research topic to synthesize (e.g., 'competitor pricing', 'React frameworks')"),
            "days_back": JSONSchema.integer(description: "How many days back to search (default 1, max 30)", minimum: 1, maximum: 30),
        ], required: ["topic"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let topic = try requiredString("topic", from: args)

        // Try real-time synthesis first
        await CrossAppSynthesizer.shared.forceSynthesis()
        let active = await CrossAppSynthesizer.shared.getActiveInsights()
            .filter { $0.type == .researchAggregation }

        if !active.isEmpty {
            var lines = ["## Research Synthesis for '\(topic)':"]
            for insight in active {
                lines.append("")
                lines.append("### \(insight.title)")
                lines.append(insight.summary)
                lines.append("**Sources:** \(insight.sources.count) | **Apps:** \(insight.connectedApps.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }

        // Fallback: check browser trail
        let trail = await MainActor.run { BrowserTrailStore.shared.currentTrail }
        let topicLower = topic.lowercased()
        let matching = trail.filter {
            $0.title.lowercased().contains(topicLower) ||
            $0.summary.lowercased().contains(topicLower)
        }

        guard !matching.isEmpty else {
            return "No research activity found for '\(topic)'. The user may not have browsed this topic recently."
        }

        var lines = ["## Browser Research Trail for '\(topic)' (\(matching.count) sources):"]
        for entry in matching {
            lines.append("- **\(entry.title)**: \(String(entry.summary.prefix(200)))")
        }
        lines.append("\nThis is raw trail data — deeper insights will emerge as the user continues researching.")
        return lines.joined(separator: "\n")
    }
}

/// Comprehensive meeting prep — gathers all context for an upcoming meeting.
struct PrepareMeetingTool: ToolDefinition {
    let name = "prepare_meeting"
    let description = "Prepare for an upcoming meeting by gathering all relevant context: related goals, recent work sessions, screen activity, browser research, and deadline alerts. Use when the user has a meeting coming up and needs a prep brief."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "meeting_title": JSONSchema.string(description: "Title of the meeting to prepare for. If omitted, prepares for the next upcoming meeting."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let requestedTitle = args["meeting_title"] as? String

        // Find the target event
        if let title = requestedTitle {
            // Search upcoming events for a title match
            guard let event = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 24) else {
                return "No upcoming events found in the next 24 hours."
            }
            let snapshot = MeetingIntelligence.CalendarEventSnapshot(from: event)
            if !snapshot.title.lowercased().contains(title.lowercased()) {
                // Try harder: check all events
                return await MeetingIntelligence.gatherPrepContext(for: snapshot)
            }
            return await MeetingIntelligence.gatherPrepContext(for: snapshot)
        }

        // Default: next upcoming event
        guard let event = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 4) else {
            return "No upcoming meetings found in the next 4 hours."
        }

        let snapshot = MeetingIntelligence.CalendarEventSnapshot(from: event)
        return await MeetingIntelligence.gatherPrepContext(for: snapshot)
    }
}

/// Check current meeting status — are we in a meeting, approaching one, or just finished?
struct MeetingStatusTool: ToolDefinition {
    let name = "meeting_status"
    let description = "Check the user's current meeting status: whether they're in a meeting, one is upcoming, or one just ended. Also reports which meeting app is active. Use to understand the user's meeting context before taking actions."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let state = MeetingIntelligence.currentState(currentApp: frontApp, windowTitle: "")

        var lines: [String] = []

        switch state.phase {
        case .none:
            lines.append("**Status:** No meeting detected")
            if let next = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 4) {
                let minutesUntil = Int(next.startDate.timeIntervalSinceNow / 60)
                lines.append("**Next event:** \(next.title ?? "Untitled") in \(minutesUntil) min")
            } else {
                lines.append("No upcoming events in the next 4 hours.")
            }

        case .upcoming:
            guard let event = state.currentEvent else { break }
            let minutesUntil = max(1, Int(event.startDate.timeIntervalSinceNow / 60))
            lines.append("**Status:** Meeting upcoming")
            lines.append("**Event:** \(event.title) in \(minutesUntil) min")
            if let loc = event.location, !loc.isEmpty { lines.append("**Location:** \(loc)") }
            if event.attendeeCount > 0 { lines.append("**Attendees:** \(event.attendeeCount)") }

        case .active:
            guard let event = state.currentEvent else { break }
            lines.append("**Status:** In meeting")
            lines.append("**Event:** \(event.title) (\(state.minutesElapsed) min elapsed)")
            if let app = state.meetingApp { lines.append("**App:** \(app)") }
            if let loc = event.location, !loc.isEmpty { lines.append("**Location:** \(loc)") }

        case .justEnded:
            lines.append("**Status:** Meeting just ended")
            if let app = state.meetingApp { lines.append("**App:** \(app) still active") }
        }

        return lines.joined(separator: "\n")
    }
}

/// Project rollup — multi-session status report from journal history.
struct SynthesizeProjectTool: ToolDefinition {
    let name = "synthesize_project"
    let description = "Produce a multi-session project status rollup. Correlates work journals across days to show progress on a topic or goal. Use when the user asks about project progress or you need to understand multi-day work patterns."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "topic": JSONSchema.string(description: "The project or goal to summarize (e.g., 'pitch deck', 'API migration')"),
            "days_back": JSONSchema.integer(description: "How many days back to search (default 7, max 90)", minimum: 1, maximum: 90),
        ], required: ["topic"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let topic = try requiredString("topic", from: args)
        let daysBack = (args["days_back"] as? Int) ?? 7

        guard let insight = await CrossAppSynthesizer.shared.synthesizeProject(topic: topic, daysBack: daysBack) else {
            return "No work sessions found for '\(topic)' in the last \(daysBack) days. Try a broader topic or longer time range."
        }

        var lines = ["## Project Rollup: \(insight.title)"]
        lines.append("")
        lines.append(insight.summary)
        lines.append("")
        lines.append("**Sessions:** \(insight.sources.count) | **Apps:** \(insight.connectedApps.joined(separator: ", "))")
        if !insight.connectedTopics.isEmpty {
            lines.append("**Topics:** \(insight.connectedTopics.joined(separator: ", "))")
        }
        if insight.actionability != .informational {
            lines.append("**Suggested action:** \(insight.actionability.rawValue)")
        }

        return lines.joined(separator: "\n")
    }
}
