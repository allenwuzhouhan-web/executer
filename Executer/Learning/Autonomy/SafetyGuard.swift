import Foundation

/// Hard safety limits for autonomous execution. Cannot be overridden.
enum SafetyGuard {

    /// Maximum autonomous actions per hour.
    static let maxActionsPerHour = 100
    /// Maximum consecutive failures before auto-pause.
    static let maxConsecutiveFailures = 3

    /// Actions that ALWAYS require approval regardless of autonomy level.
    private static let alwaysApproveTools: Set<String> = [
        "send_message", "send_imessage", "send_wechat_message",
        "trash_file", "delete_file", "move_to_trash",
        "run_shell_command", "run_terminal_command",
    ]

    /// Check if a tool call is safe for autonomous execution.
    static func isSafe(toolName: String) -> Bool {
        return !alwaysApproveTools.contains(toolName)
    }

    /// Check if a template step requires approval.
    static func requiresApproval(_ step: WorkflowTemplate.TemplateStep) -> Bool {
        return alwaysApproveTools.contains(step.toolName)
    }

    /// Check if we've exceeded the hourly action limit.
    static func isWithinHourlyLimit(actionCount: Int) -> Bool {
        return actionCount < maxActionsPerHour
    }
}
