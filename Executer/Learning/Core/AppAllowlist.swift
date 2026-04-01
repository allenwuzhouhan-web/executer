import Foundation

/// Controls which apps the Learning system is allowed to observe.
/// Defaults to allow-all except Executer itself. User can customize.
enum AppAllowlist {

    private static let defaultBlockedBundleIds: Set<String> = [
        "com.allenwu.executer",           // Never observe ourselves
        "com.apple.Terminal",             // Contains commands, credentials, API keys, SSH sessions
        "com.googlecode.iterm2",          // Same as Terminal
        "dev.warp.Warp-Stable",           // Same as Terminal
        "com.mitchellh.ghostty",          // Same as Terminal
        "net.kovidgoyal.kitty",           // Same as Terminal
        "co.zeit.hyper",                  // Same as Terminal
        "com.apple.Keychain-Access",      // Passwords and secrets
        "com.1password.1password",        // Password manager
        "com.agilebits.onepassword7",     // Password manager
    ]

    /// Check if an app is allowed for observation.
    static func isAllowed(_ bundleId: String?) -> Bool {
        guard let bundleId = bundleId else { return false }

        // Always blocked
        if defaultBlockedBundleIds.contains(bundleId) { return false }

        // Check user's custom block list
        let blocked = Set(UserDefaults.standard.stringArray(forKey: "learning_blocked_apps") ?? [])
        return !blocked.contains(bundleId)
    }

    /// Block an app from being observed.
    static func block(_ bundleId: String) {
        var blocked = UserDefaults.standard.stringArray(forKey: "learning_blocked_apps") ?? []
        if !blocked.contains(bundleId) {
            blocked.append(bundleId)
            UserDefaults.standard.set(blocked, forKey: "learning_blocked_apps")
        }
    }

    /// Unblock an app.
    static func unblock(_ bundleId: String) {
        var blocked = UserDefaults.standard.stringArray(forKey: "learning_blocked_apps") ?? []
        blocked.removeAll { $0 == bundleId }
        UserDefaults.standard.set(blocked, forKey: "learning_blocked_apps")
    }

    /// Get list of blocked apps.
    static func blockedApps() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "learning_blocked_apps") ?? []
    }
}
