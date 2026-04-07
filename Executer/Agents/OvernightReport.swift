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
    var jobResults: JobRunResult?       // Structured job results (email, files, calendar, research)
    var synthesisInsights: [SynthesisInsight]?  // Cross-domain connections noticed
    var explorationResult: ExplorationResultSummary?

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

        // Structured job results
        if let jobs = jobResults {
            lines.append("## Overnight Jobs")
            for job in jobs.jobs {
                let icon = job.status == .completed ? "+" : job.status == .failed ? "x" : "-"
                lines.append("### [\(icon)] \(job.name)")
                lines.append(job.summary)
                for action in job.actions {
                    lines.append("  - \(action)")
                }
                if let path = job.outputPath {
                    lines.append("  Output: `\(path)`")
                }
                lines.append("")
            }
        }

        // Synthesis — cross-domain connections noticed
        if let insights = synthesisInsights, !insights.isEmpty {
            lines.append("## Connections Noticed")
            for insight in insights {
                lines.append("### \(insight.headline)")
                lines.append(insight.explanation)
                lines.append("*Across: \(insight.domains.joined(separator: ", "))*")
                if let action = insight.actionSuggestion {
                    lines.append("→ \(action)")
                }
                lines.append("")
            }
        }

        // UI Exploration
        if let exploration = explorationResult, !exploration.appsExplored.isEmpty {
            lines.append("## UI Exploration")
            lines.append("**\(exploration.totalElementsLearned) new UI behaviors learned** across \(exploration.appsExplored.count) apps (\(exploration.durationSeconds / 60) min)")
            for app in exploration.appsExplored {
                let sections = app.sectionsVisited.isEmpty ? "" : " — sections: \(app.sectionsVisited.prefix(5).joined(separator: ", "))"
                lines.append("- **\(app.appName)**: \(app.elementsLearned) new elements\(sections) (\(app.stoppedReason))")
            }
            if !exploration.costYuan.isEmpty {
                let costs = exploration.costYuan.map { "\($0.key): \(String(format: "%.2f", $0.value)) yuan" }
                lines.append("*API cost: \(costs.joined(separator: ", "))*")
            }
            lines.append("")
        }

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

// MARK: - Exploration Result Summary (Codable wrapper)

/// Codable summary of UI exploration results for persistence in OvernightReport.
struct ExplorationResultSummary: Codable {
    struct AppSummary: Codable {
        let appName: String
        let elementsLearned: Int
        let sectionsVisited: [String]
        let stoppedReason: String
    }

    let appsExplored: [AppSummary]
    let totalElementsLearned: Int
    let durationSeconds: Int
    let costYuan: [String: Double]  // provider → yuan

    /// Create from UIExplorationOrchestrator result.
    init(from result: UIExplorationOrchestrator.ExplorationResult) {
        self.appsExplored = result.appsExplored.map {
            AppSummary(appName: $0.appName, elementsLearned: $0.elementsLearned,
                       sectionsVisited: $0.sectionsVisited, stoppedReason: $0.stoppedReason)
        }
        self.totalElementsLearned = result.totalElementsLearned
        self.durationSeconds = result.durationSeconds
        self.costYuan = Dictionary(result.costSummary.map { ($0.provider, $0.yuan) },
                                   uniquingKeysWith: { _, last in last })
    }
}
