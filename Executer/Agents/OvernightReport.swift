import Foundation

/// Morning briefing report generated after an overnight agent session.
struct OvernightReport: Codable {
    let sessionId: UUID
    let startTime: Date
    let endTime: Date
    let tasksCompleted: [OvernightTask]
    let tasksFailed: [OvernightTask]
    let tasksSkipped: [OvernightTask]
    let tasksNeedingReview: [OvernightTask]
    let totalActionsExecuted: Int
    let agentChainsUsed: Int
    let estimatedTimeSavedMinutes: Int

    /// Generate a markdown report.
    func toMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# Overnight Agent Report")
        lines.append("**Session:** \(formatter.string(from: startTime)) — \(formatter.string(from: endTime))")
        lines.append("**Actions executed:** \(totalActionsExecuted) | **Agent chains:** \(agentChainsUsed)")
        lines.append("**Estimated time saved:** \(estimatedTimeSavedMinutes) minutes")
        lines.append("")

        // Completed
        if !tasksCompleted.isEmpty {
            lines.append("## Completed (\(tasksCompleted.count))")
            for task in tasksCompleted {
                let conf = task.result.map { "\(Int($0.confidence * 100))% confidence" } ?? ""
                lines.append("- **\(task.title)** [\(task.source.rawValue)] — \(task.result?.summary ?? "Done") (\(conf))")
                if let path = task.result?.outputPath {
                    lines.append("  Output: `\(path)`")
                }
            }
            lines.append("")
        }

        // Needs review
        if !tasksNeedingReview.isEmpty {
            lines.append("## Needs Your Review (\(tasksNeedingReview.count))")
            for task in tasksNeedingReview {
                lines.append("- **\(task.title)** [\(task.source.rawValue)] — \(task.description)")
            }
            lines.append("")
        }

        // Failed
        if !tasksFailed.isEmpty {
            lines.append("## Failed (\(tasksFailed.count))")
            for task in tasksFailed {
                lines.append("- **\(task.title)** — \(task.result?.summary ?? "Unknown error")")
            }
            lines.append("")
        }

        // Skipped
        if !tasksSkipped.isEmpty {
            lines.append("## Skipped (\(tasksSkipped.count))")
            for task in tasksSkipped {
                lines.append("- \(task.title) — \(task.result?.summary ?? "No matching workflow")")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Short summary for notifications/WeChat.
    func toNotificationSummary() -> String {
        let total = tasksCompleted.count + tasksFailed.count + tasksSkipped.count + tasksNeedingReview.count
        var parts = ["Overnight: \(tasksCompleted.count)/\(total) tasks done"]
        if !tasksNeedingReview.isEmpty {
            parts.append("\(tasksNeedingReview.count) need review")
        }
        if estimatedTimeSavedMinutes > 0 {
            parts.append("~\(estimatedTimeSavedMinutes)min saved")
        }
        return parts.joined(separator: " | ")
    }

    /// Save report to Desktop as markdown.
    func saveToDisk() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "Overnight Report \(formatter.string(from: startTime)).md"
        let url = URL.homeDirectory.appendingPathComponent("Desktop/\(filename)")
        try? toMarkdown().write(to: url, atomically: true, encoding: .utf8)

        // Also save to App Support for history
        let historyDir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer/overnight_reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let historyURL = historyDir.appendingPathComponent("\(sessionId.uuidString).json")
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}
