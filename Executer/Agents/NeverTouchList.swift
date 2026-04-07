import Foundation

/// Hard safety guardrail for autonomous overnight execution.
/// Tools and actions on this list are NEVER executed without explicit user approval,
/// regardless of confidence score or trust level.
enum NeverTouchList {

    // MARK: - Hard Defaults (cannot be overridden by user)

    private static let hardBlockedTools: Set<String> = [
        "shutdown", "restart", "log_out",
        "run_shell_command", "run_terminal_command",
        "force_quit_app",
    ]

    // MARK: - Soft Defaults (user can remove these)

    private static let softDefaultTools: Set<String> = [
        "send_wechat_message", "send_message", "send_imessage", "send_whatsapp_message",
        "trash_file", "delete_file", "move_to_trash",
        "move_file",
        "browser_execute_js",
    ]

    // MARK: - Blocked Action Keywords

    private static let blockedKeywords: [String] = [
        "managebac", "submit", "submission",
        "payment", "pay", "transfer money", "transaction",
        "publish", "post publicly", "make public",
        "git push", "deploy", "release",
    ]

    private static let userDefaultsKey = "com.executer.overnight.neverTouchTools"

    // MARK: - Checking

    /// Check if a tool is forbidden for overnight autonomous execution.
    static func isForbidden(toolName: String) -> Bool {
        let name = toolName.lowercased()
        if hardBlockedTools.contains(name) { return true }
        return userBlockedTools().contains(name)
    }

    /// Check if an action description contains forbidden keywords.
    static func isForbidden(actionDescription: String) -> Bool {
        let desc = actionDescription.lowercased()
        return blockedKeywords.contains(where: { desc.contains($0) })
    }

    // MARK: - User Configuration

    /// Get the current user-configured blocked tools list.
    static func userBlockedTools() -> Set<String> {
        if let stored = UserDefaults.standard.stringArray(forKey: userDefaultsKey) {
            return Set(stored)
        }
        return softDefaultTools
    }

    /// Add a tool to the user's blocked list.
    static func addToUserList(_ toolName: String) {
        var list = userBlockedTools()
        list.insert(toolName.lowercased())
        UserDefaults.standard.set(Array(list), forKey: userDefaultsKey)
    }

    /// Remove a tool from the user's blocked list (cannot remove hard defaults).
    static func removeFromUserList(_ toolName: String) {
        let name = toolName.lowercased()
        guard !hardBlockedTools.contains(name) else { return }
        var list = userBlockedTools()
        list.remove(name)
        UserDefaults.standard.set(Array(list), forKey: userDefaultsKey)
    }

    /// Reset to soft defaults.
    static func resetToDefaults() {
        UserDefaults.standard.set(Array(softDefaultTools), forKey: userDefaultsKey)
    }

    /// Get all blocked tools (hard + user) for display.
    static func allBlockedTools() -> Set<String> {
        hardBlockedTools.union(userBlockedTools())
    }

    // MARK: - Workspace-Aware File Operations

    /// Check if a file operation is allowed within the designated workspace.
    /// move_file and copy_file are ALLOWED when:
    ///   - Both source AND destination are within ~/Documents/works/G8/
    ///   - OR source is in ~/Downloads/ and destination is in workspace
    /// trash_file is ONLY allowed for system junk (.DS_Store, ~$ lock files).
    static func isAllowedInWorkspace(toolName: String, arguments: String) -> Bool {
        let tool = toolName.lowercased()
        let config = WorkspaceConfig.shared

        switch tool {
        case "move_file", "copy_file":
            // Parse source and destination from arguments
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            let source = (args["source"] as? String ?? args["file_path"] as? String ?? args["from"] as? String ?? "")
            let destination = (args["destination"] as? String ?? args["new_path"] as? String ?? args["to"] as? String ?? "")

            let sourceOK = config.isInWorkspace(source) || config.isInDownloads(source)
            let destOK = config.isInWorkspace(destination)

            return sourceOK && destOK

        case "trash_file", "delete_file", "move_to_trash":
            // Only allowed for junk files
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let filePath = args["file_path"] as? String ?? args["path"] as? String else {
                return false
            }

            let filename = (filePath as NSString).lastPathComponent
            return WorkspaceConfig.isJunkFile(filename) && config.isInWorkspace(filePath)

        default:
            return false
        }
    }
}
