import Foundation

struct LockScreenTool: ToolDefinition {
    let name = "lock_screen"
    let description = "Lock the screen"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        _ = try ShellRunner.run(
            "\"/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession\" -suspend"
        )
        return "Screen locked."
    }
}

struct SleepDisplayTool: ToolDefinition {
    let name = "sleep_display"
    let description = "Turn off the display (the Mac stays awake)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        _ = try ShellRunner.run("pmset displaysleepnow")
        return "Display sleeping."
    }
}

struct SleepSystemTool: ToolDefinition {
    let name = "sleep_system"
    let description = "Put the Mac to sleep"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        _ = try ShellRunner.run("pmset sleepnow")
        return "Putting Mac to sleep."
    }
}

struct ShutdownTool: ToolDefinition {
    let name = "shutdown"
    let description = "Shut down the Mac (will show a confirmation dialog)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"System Events\" to shut down")
        return "Shutting down..."
    }
}

struct RestartTool: ToolDefinition {
    let name = "restart"
    let description = "Restart the Mac (will show a confirmation dialog)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"System Events\" to restart")
        return "Restarting..."
    }
}

struct PreventSleepTool: ToolDefinition {
    let name = "prevent_sleep"
    let description = "Prevent the Mac from sleeping for a specified number of minutes"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "minutes": JSONSchema.integer(description: "Number of minutes to prevent sleep", minimum: 1, maximum: 480)
        ], required: ["minutes"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let minutes = optionalInt("minutes", from: args) ?? 60
        let seconds = minutes * 60
        // Launch caffeinate in background
        _ = try ShellRunner.run("caffeinate -d -i -t \(seconds) &")
        return "Preventing sleep for \(minutes) minutes."
    }
}

struct LogOutTool: ToolDefinition {
    let name = "log_out"
    let description = "Log out of the current user account"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"System Events\" to log out")
        return "Logging out..."
    }
}
