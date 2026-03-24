import Cocoa

// MARK: - Launch App

struct LaunchAppTool: ToolDefinition {
    let name = "launch_app"
    let description = "Launch an application by name (e.g., 'Safari', 'Terminal', 'Xcode')"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The name of the application to launch")
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: appName)) {
            let config = NSWorkspace.OpenConfiguration()
            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return "Launched \(appName)."
        }

        // Fallback: search by name in /Applications
        let result = try ShellRunner.run("open -a \"\(appName.replacingOccurrences(of: "\"", with: "\\\""))\"")
        if result.exitCode == 0 {
            return "Launched \(appName)."
        }
        return "Could not find \(appName)."
    }

    private func bundleID(for appName: String) -> String {
        let known: [String: String] = [
            "safari": "com.apple.Safari",
            "finder": "com.apple.finder",
            "terminal": "com.apple.Terminal",
            "music": "com.apple.Music",
            "notes": "com.apple.Notes",
            "messages": "com.apple.MobileSMS",
            "mail": "com.apple.mail",
            "calendar": "com.apple.iCal",
            "reminders": "com.apple.reminders",
            "photos": "com.apple.Photos",
            "maps": "com.apple.Maps",
            "facetime": "com.apple.FaceTime",
            "preview": "com.apple.Preview",
            "textedit": "com.apple.TextEdit",
            "system settings": "com.apple.systempreferences",
            "app store": "com.apple.AppStore",
            "xcode": "com.apple.dt.Xcode",
            "chrome": "com.google.Chrome",
            "firefox": "org.mozilla.firefox",
            "slack": "com.tinyspeck.slackmacgap",
            "discord": "com.hnc.Discord",
            "spotify": "com.spotify.client",
            "vscode": "com.microsoft.VSCode",
            "visual studio code": "com.microsoft.VSCode",
        ]
        return known[appName.lowercased()] ?? "com.apple.\(appName)"
    }
}

// MARK: - Quit App

struct QuitAppTool: ToolDefinition {
    let name = "quit_app"
    let description = "Quit an application by name"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The name of the application to quit")
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)
        let safeAppName = AppleScriptRunner.escape(appName)
        try AppleScriptRunner.runThrowing("tell application \"\(safeAppName)\" to quit")
        return "Quit \(appName)."
    }
}

// MARK: - Force Quit App

struct ForceQuitAppTool: ToolDefinition {
    let name = "force_quit_app"
    let description = "Force quit a hung or unresponsive application"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The name of the application to force quit")
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            app.forceTerminate()
            return "Force quit \(appName)."
        }
        return "\(appName) is not running."
    }
}

// MARK: - Switch to App

struct SwitchToAppTool: ToolDefinition {
    let name = "switch_to_app"
    let description = "Bring an application to the front"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The name of the application to switch to")
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            app.activate()
            return "Switched to \(appName)."
        }
        return "\(appName) is not running."
    }
}

// MARK: - Hide App

struct HideAppTool: ToolDefinition {
    let name = "hide_app"
    let description = "Hide an application"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The name of the application to hide")
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            app.hide()
            return "Hid \(appName)."
        }
        return "\(appName) is not running."
    }
}

// MARK: - List Running Apps

struct ListRunningAppsTool: ToolDefinition {
    let name = "list_running_apps"
    let description = "List all currently running applications"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        return "Running apps: \(apps.joined(separator: ", "))"
    }
}
