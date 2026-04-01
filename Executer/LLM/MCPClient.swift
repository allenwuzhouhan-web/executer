import Foundation

/// Lightweight MCP (Model Context Protocol) client using stdio transport.
/// Connects to MCP servers as child processes, communicates via JSON-RPC 2.0.
actor MCPClient {
    let serverName: String
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutHandle: FileHandle?
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId = 1
    private var readBuffer = Data()
    private var isConnected = false
    private var readTask: Task<Void, Never>?

    struct MCPTool {
        let name: String
        let description: String
        let inputSchema: [String: Any]
    }

    init(name: String) {
        self.serverName = name
    }

    // MARK: - Connection

    func connect(command: String, args: [String], env: [String: String] = [:]) async throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var procEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { procEnv[k] = v }
        // Ensure node/npx can be found
        procEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(procEnv["PATH"] ?? "")"
        proc.environment = procEnv

        try proc.run()
        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.isConnected = true

        // Start reading responses on a background task
        let handle = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — server disconnected
                    await self?.handleDisconnect()
                    break
                }
                await self?.handleData(data)
            }
        }

        // Send MCP initialize
        let initResult = try await sendRequest("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Executer", "version": "1.0"]
        ])

        // Send initialized notification (no response expected)
        sendNotification("notifications/initialized", params: [:])

        let serverName = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP] Connected to \(serverName)")
    }

    func disconnect() {
        isConnected = false
        // Close stdout first to force EOF on readTask's availableData
        stdoutHandle?.closeFile()
        stdoutHandle = nil
        readTask?.cancel()
        readTask = nil
        stdin?.closeFile()
        stdin = nil
        process?.terminate()
        process = nil
        // Cancel any pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - MCP Operations

    func listTools() async throws -> [MCPTool] {
        let result = try await sendRequest("tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let desc = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            return MCPTool(name: name, description: desc, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest("tools/call", params: [
            "name": name,
            "arguments": arguments
        ], timeout: 30)

        // MCP returns content as an array of content blocks
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }

        // Fallback: serialize the whole result
        if let data = try? JSONSerialization.data(withJSONObject: result, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Tool executed successfully (no text output)"
    }

    // MARK: - JSON-RPC 2.0 Transport

    private func sendRequest(_ method: String, params: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard isConnected, stdin != nil else { throw MCPError.disconnected }

        let id = nextId
        nextId += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let messageData = try JSONSerialization.data(withJSONObject: message)
        let header = "Content-Length: \(messageData.count)\r\n\r\n"

        guard let headerData = header.data(using: .utf8) else {
            throw MCPError.encodingError
        }

        // Write to pipe safely (catch broken pipe)
        guard let pipe = stdin, process?.isRunning == true else {
            throw MCPError.disconnected
        }
        do {
            try pipe.write(contentsOf: headerData)
            try pipe.write(contentsOf: messageData)
        } catch {
            throw MCPError.disconnected
        }

        // Register the continuation, then race against timeout
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation

            // Start a timeout task
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If still pending after timeout, resume with error
                if let cont = self.pendingRequests.removeValue(forKey: id) {
                    cont.resume(throwing: MCPError.timeout)
                }
            }
        }
        return result
    }

    private func sendNotification(_ method: String, params: [String: Any]) {
        guard isConnected, let pipe = stdin, process?.isRunning == true else { return }
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        if let headerData = header.data(using: .utf8) {
            try? pipe.write(contentsOf: headerData)
            try? pipe.write(contentsOf: data)
        }
    }

    // MARK: - Response Parsing

    private func handleData(_ data: Data) {
        readBuffer.append(data)
        // Parse Content-Length framed messages
        while let message = extractMessage() {
            processMessage(message)
        }
    }

    private func extractMessage() -> [String: Any]? {
        guard let headerEnd = readBuffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = readBuffer[readBuffer.startIndex..<headerEnd.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let lengthLine = headerStr.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
              let length = Int(lengthLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        else { return nil }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = readBuffer.index(bodyStart, offsetBy: length, limitedBy: readBuffer.endIndex)
        guard let end = bodyEnd, end <= readBuffer.endIndex else { return nil }

        let bodyData = readBuffer[bodyStart..<end]
        readBuffer = Data(readBuffer[end...])

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { return nil }
        return json
    }

    private func processMessage(_ message: [String: Any]) {
        // Response (has "id") — support both Int and NSNumber from JSONSerialization
        if let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue,
           let continuation = pendingRequests.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown MCP error"
                let code = error["code"] as? Int ?? -1
                continuation.resume(throwing: MCPError.serverError(code: code, message: msg))
            } else {
                let result = message["result"] as? [String: Any] ?? [:]
                continuation.resume(returning: result)
            }
        }
        // Notifications (no "id") — log but don't process
    }

    private func handleDisconnect() {
        guard isConnected else { return }  // Prevent double-disconnect
        isConnected = false
        stdin?.closeFile()
        stdin = nil
        process?.terminate()
        process = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
        print("[MCP] Server \(serverName) disconnected")
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case disconnected
    case encodingError
    case serverError(code: Int, message: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .disconnected: return "MCP server disconnected"
        case .encodingError: return "Failed to encode MCP message"
        case .serverError(_, let msg): return "MCP server error: \(msg)"
        case .timeout: return "MCP request timed out"
        }
    }
}
