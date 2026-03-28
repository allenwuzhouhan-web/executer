import Foundation

/// Per-tool error recovery strategies.
enum ErrorRecoveryStrategy {

    enum Strategy {
        case retry(maxAttempts: Int)
        case skip
        case abort
        case alternative(toolName: String)
    }

    /// Get the recovery strategy for a failed tool.
    static func strategy(for toolName: String, error: String) -> Strategy {
        // UI tools: retry with adaptive finding
        if ["click_element", "type_text"].contains(toolName) {
            if error.contains("not found") || error.contains("element") {
                return .retry(maxAttempts: 2)
            }
        }

        // App launch: retry once
        if toolName == "launch_app" {
            return .retry(maxAttempts: 1)
        }

        // Critical operations: abort
        if ["run_shell_command", "trash_file"].contains(toolName) {
            return .abort
        }

        // Default: skip and continue
        return .skip
    }
}
