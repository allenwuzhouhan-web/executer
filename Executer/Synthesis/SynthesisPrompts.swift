import Foundation

/// LLM prompt templates for real-time synthesis tasks.
enum SynthesisPrompts {

    /// Prompt to synthesize cross-app activity into a coherent insight.
    /// Optionally enriched with calendar/meeting context.
    static func crossAppFusionPrompt(
        observations: [(app: String, intent: String, topics: [String])],
        meetingContext: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("The user has been active across multiple apps simultaneously. Here is what they are doing:")
        lines.append("")
        for obs in observations {
            lines.append("- **\(obs.app)**: \(obs.intent) (topics: \(obs.topics.joined(separator: ", ")))")
        }
        if let meeting = meetingContext {
            lines.append("")
            lines.append(meeting)
        }
        lines.append("")
        lines.append("Synthesize these activities into a single coherent insight:")
        lines.append("1. What is the user's overarching goal across these apps?")
        lines.append("2. How do the activities connect?")
        if meetingContext != nil {
            lines.append("3. How does this relate to the meeting context?")
        }
        lines.append("3. Is there anything the user might need help with?")
        lines.append("")
        lines.append("Respond with ONLY a JSON object (no markdown fences):")
        lines.append("""
        {"title": "short title (under 60 chars)", "summary": "2-3 sentence synthesis", "actionability": "informational|suggestAction|urgent"}
        """)
        return lines.joined(separator: "\n")
    }

    /// Prompt to aggregate research findings from multiple browser sources.
    static func researchAggregationPrompt(
        trails: [(url: String, title: String, summary: String)],
        observations: [(app: String, intent: String)]
    ) -> String {
        var lines: [String] = []
        lines.append("The user has been researching a topic across multiple sources:")
        lines.append("")
        lines.append("**Browser trail:**")
        for trail in trails {
            lines.append("- [\(trail.title)](\(trail.url)): \(trail.summary)")
        }
        if !observations.isEmpty {
            lines.append("")
            lines.append("**Related app activity:**")
            for obs in observations {
                lines.append("- \(obs.app): \(obs.intent)")
            }
        }
        lines.append("")
        lines.append("Synthesize these research findings:")
        lines.append("1. What is the user researching?")
        lines.append("2. What are the key findings across sources?")
        lines.append("3. Are there contradictions or gaps?")
        lines.append("4. What might the user do next with this research?")
        lines.append("")
        lines.append("Respond with ONLY a JSON object (no markdown fences):")
        lines.append("""
        {"title": "short title (under 60 chars)", "summary": "2-3 sentence synthesis of key findings", "actionability": "informational|suggestAction|urgent"}
        """)
        return lines.joined(separator: "\n")
    }

    /// Prompt to produce a multi-session project rollup.
    static func projectRollupPrompt(
        journals: [(date: String, task: String, apps: [String], topics: [String])],
        goalName: String?
    ) -> String {
        var lines: [String] = []
        if let goal = goalName {
            lines.append("The user has been working toward: \"\(goal)\"")
        } else {
            lines.append("The user has been working on a project across multiple sessions:")
        }
        lines.append("")
        for j in journals {
            lines.append("- **\(j.date)**: \(j.task) (apps: \(j.apps.joined(separator: ", ")), topics: \(j.topics.joined(separator: ", ")))")
        }
        lines.append("")
        lines.append("Produce a project status rollup:")
        lines.append("1. What is the overall project/goal?")
        lines.append("2. What progress has been made?")
        lines.append("3. What remains to be done?")
        lines.append("4. Any patterns or blockers?")
        lines.append("")
        lines.append("Respond with ONLY a JSON object (no markdown fences):")
        lines.append("""
        {"title": "short title (under 60 chars)", "summary": "2-3 sentence status rollup", "actionability": "informational|suggestAction|urgent"}
        """)
        return lines.joined(separator: "\n")
    }

    /// Prompt to generate a post-meeting summary from observed activity.
    static func postMeetingPrompt(
        meetingTitle: String,
        durationMinutes: Int,
        appsUsed: [String],
        thoughts: [(app: String, content: String)]
    ) -> String {
        var lines: [String] = []
        lines.append("The user just finished a meeting: '\(meetingTitle)' (\(durationMinutes) min).")
        lines.append("")
        if !appsUsed.isEmpty {
            lines.append("**Apps used during meeting:** \(appsUsed.joined(separator: ", "))")
        }
        if !thoughts.isEmpty {
            lines.append("\n**Screen activity captured during meeting:**")
            for t in thoughts.prefix(8) {
                lines.append("- [\(t.app)] \(t.content)")
            }
        }
        lines.append("")
        lines.append("Based on the activity during the meeting:")
        lines.append("1. What was the meeting likely about?")
        lines.append("2. Were any action items or follow-ups suggested by the activity?")
        lines.append("3. What should the user do next?")
        lines.append("")
        lines.append("Respond with ONLY a JSON object (no markdown fences):")
        lines.append("""
        {"title": "short title (under 60 chars)", "summary": "2-3 sentence post-meeting synthesis", "actionability": "suggestAction"}
        """)
        return lines.joined(separator: "\n")
    }
}
