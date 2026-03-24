import Cocoa

struct RunShellCommandTool: ToolDefinition {
    let name = "run_shell_command"
    let description = "Run a shell command and return its output. Use for system tasks not covered by other tools."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "command": JSONSchema.string(description: "The shell command to execute")
        ], required: ["command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let command = try requiredString("command", from: args)
        let result = try ShellRunner.run(command)
        if result.exitCode == 0 {
            return result.output.isEmpty ? "Command completed successfully." : result.output
        }
        return "Command failed (exit \(result.exitCode)): \(result.output)"
    }
}

struct OpenTerminalTool: ToolDefinition {
    let name = "open_terminal"
    let description = "Open the Terminal application"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        _ = try ShellRunner.run("open -a Terminal")
        return "Opened Terminal."
    }
}

struct OpenTerminalWithCommandTool: ToolDefinition {
    let name = "open_terminal_with_command"
    let description = "Open Terminal and run a command in it (visible to the user)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "command": JSONSchema.string(description: "The command to run in the new Terminal window")
        ], required: ["command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let command = try requiredString("command", from: args)
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        try AppleScriptRunner.runThrowing("tell application \"Terminal\" to do script \"\(escaped)\"")
        try AppleScriptRunner.runThrowing("tell application \"Terminal\" to activate")
        return "Running command in Terminal."
    }
}
