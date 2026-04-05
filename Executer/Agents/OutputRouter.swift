import Foundation

/// Routes overnight agent results and reports to the correct destinations.
/// Uses existing tools for delivery — no new infrastructure.
enum OutputRouter {

    /// Route a completed overnight report to all channels.
    static func route(_ report: OvernightReport) async {
        // 1. Always save to Desktop as markdown
        report.saveToDisk()
        print("[OutputRouter] Saved report to Desktop")

        // 2. System notification (short summary)
        let summary = report.toNotificationSummary()
        do {
            let argsData = try JSONSerialization.data(withJSONObject: [
                "title": "Overnight Agent Complete",
                "message": summary,
                "sound": true
            ] as [String: Any])
            let args = String(data: argsData, encoding: .utf8) ?? "{}"
            _ = try await ToolRegistry.shared.execute(toolName: "show_notification", arguments: args)
        } catch {
            print("[OutputRouter] Notification failed: \(error)")
        }

        // 3. Post notification for morning briefing card (UI will pick this up)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .overnightReportReady,
                object: nil,
                userInfo: ["report": report]
            )
        }
    }

    /// Route a single task result (for real-time progress during overnight session).
    static func routeTaskResult(_ task: OvernightTask) async {
        guard let result = task.result else { return }

        // Log the completion
        if task.state == .completed {
            print("[OutputRouter] Task completed: \(task.title) — \(result.summary)")
        } else if task.state == .failed {
            print("[OutputRouter] Task failed: \(task.title) — \(result.summary)")
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let overnightReportReady = Notification.Name("com.executer.overnight.reportReady")
    static let overnightAgentStateChanged = Notification.Name("com.executer.overnight.stateChanged")
}
