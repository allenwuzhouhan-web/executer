import Foundation
import AppKit

extension LocalCommandRouter {

    /// Common aliases for app names that differ from the actual app bundle name.
    /// Only for cases where the user's name is significantly different from the real name.
    /// LaunchAppTool already handles bundle ID lookup — this is for the pattern matcher layer.
    private static let appAliases: [String: String] = [
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "chrome": "Google Chrome", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "ppt": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook", "teams": "Microsoft Teams",
        "iterm": "iTerm", "iterm2": "iTerm",
        "system settings": "System Settings", "system preferences": "System Settings",
        "app store": "App Store",
        "activity monitor": "Activity Monitor",
        "text edit": "TextEdit", "textedit": "TextEdit",
        "face time": "FaceTime", "facetime": "FaceTime",
    ]

    func tryAppCommand(_ input: String) async -> String? {
        let prefixes: [(prefix: String, action: String)] = [
            ("open ", "launch"), ("launch ", "launch"), ("start ", "launch"),
            ("quit ", "quit"), ("close ", "quit"), ("kill ", "quit"),
            ("force quit ", "force_quit"),
            ("switch to ", "switch"), ("bring up ", "switch"),
        ]
        for (prefix, action) in prefixes {
            guard input.hasPrefix(prefix) else { continue }
            let rawName = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { continue }

            // Resolve alias first: "chrome" → "Google Chrome"
            let appName = Self.appAliases[rawName.lowercased()] ?? rawName

            // Skip if it looks like a file path, URL, or web navigation (let other matchers handle)
            if Self.looksLikeNonApp(appName, action: action) { return nil }

            // For "open" — verify it's actually an app before intercepting
            // This replaces the brittle nonAppWords blocklist
            if action == "launch" {
                let resolved = Self.resolveAppName(appName)
                if resolved == nil && !Self.isLikelyAppName(appName) { return nil }
                let finalName = resolved ?? appName
                let jsonArg = "{\"app_name\": \"\(escapeJSON(finalName))\"}"
                return try? await LaunchAppTool().execute(arguments: jsonArg)
            }

            let jsonArg = "{\"app_name\": \"\(escapeJSON(appName))\"}"
            switch action {
            case "quit":
                return try? await QuitAppTool().execute(arguments: jsonArg)
            case "force_quit":
                return try? await ForceQuitAppTool().execute(arguments: jsonArg)
            case "switch":
                return try? await SwitchToAppTool().execute(arguments: jsonArg)
            default:
                break
            }
        }

        // "hide [app]"
        if input.hasPrefix("hide ") {
            let rawName = String(input.dropFirst("hide ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty && rawName != "all windows" {
                let appName = Self.appAliases[rawName.lowercased()] ?? rawName
                return try? await HideAppTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        return nil
    }

    // MARK: - App Resolution

    /// Checks /Applications and running apps to see if a name matches a real app.
    /// Returns the canonical app name if found, nil otherwise.
    private static func resolveAppName(_ name: String) -> String? {
        let lower = name.lowercased()

        // Check running apps first (fast, already in memory)
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let appName = app.localizedName, appName.lowercased() == lower {
                return appName
            }
        }

        // Fuzzy match running apps: "safari" matches "Safari", "chrome" matches "Google Chrome"
        for app in runningApps {
            if let appName = app.localizedName, appName.lowercased().contains(lower) {
                return appName
            }
        }

        // Check /Applications (slightly slower, disk access)
        let fm = FileManager.default
        let appDirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities"]
        for dir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let appName = String(item.dropLast(4)) // Remove .app
                if appName.lowercased() == lower {
                    return appName
                }
            }
        }

        // Fuzzy match /Applications
        for dir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let appName = String(item.dropLast(4))
                if appName.lowercased().contains(lower) {
                    return appName
                }
            }
        }

        return nil
    }

    /// Heuristic: looks like an app name if it's short, capitalized, or a known alias.
    private static func isLikelyAppName(_ name: String) -> Bool {
        let words = name.split(separator: " ")
        // Single word, 2-20 chars, all letters → likely an app
        if words.count == 1 && name.count >= 2 && name.count <= 20 && name.allSatisfy({ $0.isLetter }) {
            return true
        }
        // 2-3 words, title-cased → likely an app name
        if words.count <= 3 && words.allSatisfy({ $0.first?.isUppercase == true }) {
            return true
        }
        return false
    }

    /// Returns true if the input looks like a URL, file, or web command — not an app.
    private static func looksLikeNonApp(_ name: String, action: String) -> Bool {
        let lower = name.lowercased()
        // URLs / domains
        if lower.contains("http") || lower.contains("www.") { return true }
        if lower.contains(".com") || lower.contains(".org") || lower.contains(".net") { return true }
        // File paths
        if lower.contains("/") || lower.hasPrefix("~") { return true }
        // Multi-word phrases that are clearly not app names
        if lower.hasPrefix("the ") || lower.hasPrefix("a ") || lower.hasPrefix("my ") { return true }
        // "open" + compound verb phrases
        if action == "launch" && (lower.contains(" and ") || lower.contains(" then ")) { return true }
        return false
    }
}
