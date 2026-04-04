import Foundation

/// Records each multi-step task as an episode for future recall.
final class EpisodeLogger {
    static let shared = EpisodeLogger()
    private init() {}

    struct Episode {
        let id: UUID
        let goal: String
        let plan: [String]?
        let actions: [EpisodeAction]
        let outcome: Outcome
        let failureReason: String?
        let whatWorked: String?
        let durationSeconds: Double
        let toolCount: Int
        let timestamp: Date

        enum Outcome: String {
            case success, partial, failure
        }
    }

    struct EpisodeAction {
        let tool: String
        let argsSummary: String   // First 100 chars of args
        let resultSummary: String // First 200 chars of result
        let success: Bool
    }

    /// Record a completed task episode. Called at end of AgentLoop.execute().
    func record(
        goal: String,
        plan: [String]?,
        messages: [ChatMessage],
        finalOutcome: Episode.Outcome,
        failureReason: String?,
        durationSeconds: Double
    ) {
        // Extract actions from message chain
        var actions: [EpisodeAction] = []
        var lastToolCalls: [ToolCall] = []

        for msg in messages {
            if msg.role == "assistant", let calls = msg.tool_calls {
                lastToolCalls = calls
            }
            if msg.role == "tool", let content = msg.content, let callId = msg.tool_call_id {
                if let call = lastToolCalls.first(where: { $0.id == callId }) {
                    let success = !content.lowercased().hasPrefix("error")
                    actions.append(EpisodeAction(
                        tool: call.function.name,
                        argsSummary: String(call.function.arguments.prefix(100)),
                        resultSummary: String(content.prefix(200)),
                        success: success
                    ))
                }
            }
        }

        // Only log episodes with tool calls (skip simple Q&A)
        guard actions.count >= 1 else { return }

        let episode = Episode(
            id: UUID(), goal: goal, plan: plan,
            actions: actions, outcome: finalOutcome,
            failureReason: failureReason,
            whatWorked: actions.filter(\.success).map(\.tool).joined(separator: ", "),
            durationSeconds: durationSeconds,
            toolCount: actions.count,
            timestamp: Date()
        )

        insertEpisode(episode)
    }

    private func insertEpisode(_ episode: Episode) {
        // Encode actions to JSON
        let actionsArray = episode.actions.map { action -> [String: Any] in
            ["tool": action.tool, "args": action.argsSummary, "result": action.resultSummary, "success": action.success]
        }
        let actionsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: actionsArray),
           let str = String(data: data, encoding: .utf8) {
            actionsJSON = str
        } else {
            actionsJSON = "[]"
        }

        let planJSON: String?
        if let plan = episode.plan,
           let data = try? JSONSerialization.data(withJSONObject: plan),
           let str = String(data: data, encoding: .utf8) {
            planJSON = str
        } else {
            planJSON = nil
        }

        LearningDatabase.shared.executeSQL("""
            INSERT OR IGNORE INTO episodes (id, goal, plan, actions_json, outcome, failure_reason, what_worked, duration_seconds, tool_count, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            episode.id.uuidString,
            episode.goal,
            planJSON,
            actionsJSON,
            episode.outcome.rawValue,
            episode.failureReason,
            episode.whatWorked,
            episode.durationSeconds,
            episode.toolCount,
            episode.timestamp.timeIntervalSince1970
        ])

        print("[EpisodeLogger] Recorded episode: \(episode.outcome.rawValue), \(episode.toolCount) tools, goal: \(episode.goal.prefix(60))")
    }
}
