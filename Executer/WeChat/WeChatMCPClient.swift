import Foundation

/// JSON-RPC 2.0 client that communicates with the WeChat-MCP server over stdio.
/// Manages the subprocess lifecycle, request/response matching, and auto-restart.
actor WeChatMCPClient {

    // MARK: - Types

    struct MCPResult {
        let content: [[String: Any]]
        let isError: Bool
    }

    enum MCPError: LocalizedError {
        case notRunning
        case serverCrashed(String)
        case timeout
        case invalidResponse(String)
        case toolError(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "WeChat-MCP server is not running"
            case .serverCrashed(let msg): return "WeChat-MCP server crashed: \(msg)"
            case .timeout: return "WeChat-MCP request timed out"
            case .invalidResponse(let msg): return "Invalid MCP response: \(msg)"
            case .toolError(let msg): return "WeChat tool error: \(msg)"
            }
        }
    }

    // MARK: - State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<MCPResult, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var initialized = false

    /// Path to uv binary
    private let uvPath: String
    /// Path to WeChat-MCP project directory
    private let projectPath: String

    private let toolCallTimeout: TimeInterval = 30

    var isRunning: Bool {
        process?.isRunning == true && initialized
    }

    // MARK: - Init

    init(
        uvPath: String = "\(NSHomeDirectory())/.local/bin/uv",
        projectPath: String = "\(NSHomeDirectory())/WeChat-MCP"
    ) {
        self.uvPath = uvPath
        self.projectPath = projectPath
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Don't double-start
        if process?.isRunning == true {
            if initialized { return }
            stop()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = ["run", "wechat-mcp", "--transport", "stdio"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        // Inherit PATH so uv can find python
        var env = ProcessInfo.processInfo.environment
        let localBin = "\(NSHomeDirectory())/.local/bin"
        env["PATH"] = "\(localBin):\(env["PATH"] ?? "/usr/bin")"
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc
        self.nextRequestId = 1
        self.pendingRequests = [:]
        self.initialized = false

        proc.terminationHandler = { [weak self] p in
            Task { [weak self] in
                await self?.handleTermination(exitCode: p.terminationStatus)
            }
        }

        try proc.run()
        print("[WeChatMCP] Server process started (pid: \(proc.processIdentifier))")

        // Start reading stdout in background
        readTask = Task { [weak self] in
            await self?.readLoop(pipe: stdout)
        }

        // MCP initialization handshake
        try await performHandshake()
    }

    func stop() {
        readTask?.cancel()
        readTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            print("[WeChatMCP] Server stopped")
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        initialized = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.notRunning)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Tool Calls

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPResult {
        if !isRunning {
            // Try to auto-start
            try await start()
        }

        let id = nextRequestId
        nextRequestId += 1

        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": params
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            do {
                try sendMessage(message)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(toolCallTimeout * 1_000_000_000))
                if let cont = await removePendingRequest(id: id) {
                    cont.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    private func removePendingRequest(id: Int) -> CheckedContinuation<MCPResult, Error>? {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - MCP Handshake

    private func performHandshake() async throws {
        let id = nextRequestId
        nextRequestId += 1

        let initMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "Executer",
                    "version": "1.0"
                ]
            ] as [String: Any]
        ]

        // Send initialize and wait for response
        let _: MCPResult = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            do {
                try sendMessage(initMsg)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            // 10s timeout for handshake
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = await removePendingRequest(id: id) {
                    cont.resume(throwing: MCPError.timeout)
                }
            }
        }

        // Send initialized notification (no response expected)
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        try sendMessage(notification)

        initialized = true
        print("[WeChatMCP] Handshake complete — server ready")
    }

    // MARK: - I/O

    private func sendMessage(_ message: [String: Any]) throws {
        guard let pipe = stdinPipe else {
            throw MCPError.notRunning
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        var line = data
        line.append(contentsOf: [UInt8(ascii: "\n")])
        pipe.fileHandleForWriting.write(line)
    }

    private func readLoop(pipe: Pipe) async {
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — process exited
                break
            }

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                guard !lineData.isEmpty else { continue }

                if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    await handleResponse(json)
                }
            }
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        // Match response to pending request by id
        guard let id = json["id"] as? Int else {
            // Notification or server-initiated message — ignore
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            print("[WeChatMCP] Received response for unknown id: \(id)")
            return
        }

        // Check for JSON-RPC error
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            continuation.resume(throwing: MCPError.toolError(message))
            return
        }

        // Parse result
        guard let result = json["result"] as? [String: Any] else {
            continuation.resume(throwing: MCPError.invalidResponse("Missing result field"))
            return
        }

        let content = result["content"] as? [[String: Any]] ?? []
        let isError = result["isError"] as? Bool ?? false
        continuation.resume(returning: MCPResult(content: content, isError: isError))
    }

    private func handleTermination(exitCode: Int32) {
        print("[WeChatMCP] Server exited with code \(exitCode)")
        initialized = false

        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.serverCrashed("Exit code \(exitCode)"))
        }
        pendingRequests.removeAll()
    }
}
