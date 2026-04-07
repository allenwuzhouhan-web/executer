import Foundation

/// Before executing a task, query for similar past episodes and inject context.
enum EpisodeRecall {

    /// Build a prompt section from relevant past episodes.
    static func promptSection(forGoal goal: String) -> String {
        let episodes = LearningDatabase.shared.queryEpisodes(goalQuery: goal, limit: 3)
        guard !episodes.isEmpty else { return "" }

        var lines = ["\n## Past Similar Tasks"]
        for ep in episodes {
            let status = ep.outcome == "success" ? "succeeded" : "failed"
            lines.append("- \"\(ep.goal.prefix(80))\" (\(status), \(ep.toolCount) tools)")
            if ep.outcome != "success", let reason = ep.failureReason, !reason.isEmpty {
                lines.append("  Failure: \(reason.prefix(100))")
            }
            if let worked = ep.whatWorked, !worked.isEmpty {
                lines.append("  What worked: \(worked.prefix(100))")
            }
        }
        lines.append("Use this history to avoid repeating past mistakes and reuse successful approaches.")

        let result = lines.joined(separator: "\n")
        return result.count > 1000 ? String(result.prefix(1000)) : result
    }
}
