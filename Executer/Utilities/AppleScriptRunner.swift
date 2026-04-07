import Foundation

enum AppleScriptRunner {
    /// Escapes a string for safe interpolation into AppleScript double-quoted strings.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs an AppleScript expression and returns the result string, or nil on failure.
    @discardableResult
    static func run(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            print("[AppleScript Error] \(message)")
            return nil
        }
        return result?.stringValue
    }

    /// Runs an AppleScript expression, throwing on error.
    static func runThrowing(_ source: String) throws -> String {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw ExecuterError.appleScript(message)
        }
        return result?.stringValue ?? ""
    }
}

enum ShellRunner {
    /// Runs a shell command and returns (stdout, exitCode).
    static func run(_ command: String, timeout: TimeInterval = 30) throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Apply timeout
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 && !errorOutput.isEmpty {
            return (output: output.isEmpty ? errorOutput : "\(output)\n\(errorOutput)", exitCode: process.terminationStatus)
        }

        return (output: output, exitCode: process.terminationStatus)
    }
}

// MARK: - Async Shell Runner (pipe-safe + timeout)

enum AsyncShellRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Run an executable asynchronously with proper pipe handling and SIGTERM/SIGKILL timeout.
    /// Pipe-safe: reads stdout/stderr BEFORE waitUntilExit to avoid deadlock on >64KB output.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: Int = 60
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Merge environment: inherit current + add overrides
                var env = ProcessInfo.processInfo.environment
                if let extra = environment {
                    env.merge(extra) { _, new in new }
                }
                process.environment = env

                if let dir = workingDirectory {
                    let expanded = NSString(string: dir).expandingTildeInPath
                    process.currentDirectoryURL = URL(fileURLWithPath: expanded)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Timeout: SIGTERM → 2s grace → SIGKILL
                let pid = process.processIdentifier
                var didTimeout = false
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + .seconds(timeout))
                timer.setEventHandler {
                    if process.isRunning {
                        didTimeout = true
                        kill(pid, SIGTERM)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { kill(pid, SIGKILL) }
                        }
                    }
                }
                timer.resume()

                // CRITICAL: Read pipes BEFORE waitUntilExit to avoid deadlock
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                continuation.resume(returning: Result(
                    stdout: out,
                    stderr: err,
                    exitCode: process.terminationStatus,
                    timedOut: didTimeout
                ))
            }
        }
    }
}

enum ExecuterError: LocalizedError {
    case appleScript(String)
    case shellCommand(String)
    case toolNotFound(String)
    case invalidArguments(String)
    case permissionDenied(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .appleScript(let msg): return "AppleScript error: \(msg)"
        case .shellCommand(let msg): return "Shell error: \(msg)"
        case .toolNotFound(let name): return "Unknown tool: \(name)"
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
