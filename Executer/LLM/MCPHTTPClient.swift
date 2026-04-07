import Foundation

/// MCP client using HTTP-based transports (SSE or Streamable HTTP).
/// Communicates via JSON-RPC 2.0 over HTTP POST, with SSE for server-to-client streaming.
actor MCPHTTPClient: MCPTransport {

    enum TransportMode {
        case sse            // Legacy: GET for SSE stream, POST for client→server messages
        case streamableHTTP // Current spec: POST returns JSON or SSE stream
    }

    let serverName: String
    private let url: URL
    private let mode: TransportMode
    private let customHeaders: [String: String]

    // JSON-RPC state
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, any Error>] = [:]
    private var nextId = 1

    // Connection state
    private var isConnected = false
    private var sessionId: String?           // Mcp-Session-Id from server
    private var sseTask: Task<Void, Never>?  // Long-lived SSE listener (SSE mode only)
    private var ssePostEndpoint: URL?        // POST URL discovered from SSE endpoint event

    // URLSession with long timeout for SSE streams
    private let sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300     // 5 min per-request
        config.timeoutIntervalForResource = 86400  // 24h for long-lived SSE
        return URLSession(configuration: config)
    }()

    // Reconnection
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private static let maxReconnectAttempts = 5
    private static let maxBackoffSeconds: Double = 30

    init(name: String, url: URL, mode: TransportMode, headers: [String: String] = [:]) {
        self.serverName = name
        self.url = url
        self.mode = mode
        self.customHeaders = headers
    }

    // MARK: - MCPTransport

    var isAlive: Bool {
        isConnected
    }

    func connect() async throws {
        switch mode {
        case .sse:
            try await connectSSE()
        case .streamableHTTP:
            try await connectStreamableHTTP()
        }
    }

    func disconnect() {
        isConnected = false
        sseTask?.cancel()
        sseTask = nil
        sessionId = nil
        ssePostEndpoint = nil
        // Fail all pending requests
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
        print("[MCP-HTTP] \(serverName) disconnected")
    }

    func ensureConnected() async throws {
        if isAlive { return }

        // Clean up stale state
        if isConnected { disconnect() }

        if reconnectAttempts >= Self.maxReconnectAttempts {
            reconnectAttempts = 0
        }

        print("[MCP-HTTP] Liveness check failed for \(serverName), reconnecting...")
        do {
            try await connect()
        } catch {
            throw MCPError.disconnected
        }
    }

    func listTools() async throws -> [MCPToolInfo] {
        let result = try await sendRequest("tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let desc = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            return MCPToolInfo(name: name, description: desc, inputSchema: schema)
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
                if block["type"] as? String == "text" { return block["text"] as? String }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }

        // Fallback: serialize
        if let data = try? JSONSerialization.data(withJSONObject: result, options: []),
           let str = String(data: data, encoding: .utf8) { return str }
        return "Tool executed successfully (no text output)"
    }

    // MARK: - Streamable HTTP Transport

    /// Connect via Streamable HTTP: POST-based, stateless per-request.
    private func connectStreamableHTTP() async throws {
        // Send initialize via POST, expect JSON or SSE response
        let initResult = try await sendStreamableHTTPRequest("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Executer", "version": "1.0"]
        ])

        isConnected = true
        reconnectAttempts = 0
        isReconnecting = false

        // Send initialized notification (fire-and-forget POST)
        sendStreamableHTTPNotification("notifications/initialized", params: [:])

        let name = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP-HTTP] Connected to \(name) via streamable-http")
    }

    /// Send a JSON-RPC request via Streamable HTTP POST.
    /// Handles both JSON and SSE response content types.
    private func sendStreamableHTTPRequest(_ method: String, params: [String: Any],
                                           timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard method == "initialize" || isConnected else { throw MCPError.disconnected }

        let id = nextId; nextId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        applyHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }

        // Capture session ID
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = sid
        }

        // Session expired — reconnect
        if http.statusCode == 404 && sessionId != nil {
            sessionId = nil
            isConnected = false
            throw MCPError.sessionExpired
        }

        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw MCPError.httpError(statusCode: http.statusCode, body: body)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/event-stream") {
            // SSE response — parse events until we find our response
            return try await parseSSEForResponse(bytes: bytes, expectedId: id)
        } else {
            // JSON response — collect bytes and parse
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidResponse
            }
            return extractResult(from: json)
        }
    }

    /// Fire-and-forget notification via POST (no response expected).
    private func sendStreamableHTTPNotification(_ method: String, params: [String: Any]) {
        Task {
            let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            applyHeaders(&request)
            request.httpBody = body
            _ = try? await sseSession.data(for: request)
        }
    }

    // MARK: - SSE Transport (Legacy)

    /// Connect via SSE: GET for server→client stream, POST for client→server.
    private func connectSSE() async throws {
        // 1. Open SSE stream to discover the POST endpoint
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(&request)

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MCPError.connectionFailed("SSE GET returned HTTP \(code)")
        }

        // 2. Wait for the endpoint event (first SSE event from server)
        var endpointURL: URL?
        var eventType = ""
        var dataBuffer = ""

        // Parse initial events to find the endpoint
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataBuffer += String(line.dropFirst(6))
            } else if line.isEmpty && !dataBuffer.isEmpty {
                if eventType == "endpoint" {
                    // Resolve relative URL against base
                    endpointURL = URL(string: dataBuffer, relativeTo: url)?.absoluteURL
                        ?? URL(string: dataBuffer)
                    break
                }
                // Process any JSON-RPC message that arrives during handshake
                processSSEData(dataBuffer)
                eventType = ""
                dataBuffer = ""
            }
        }

        guard let postURL = endpointURL else {
            throw MCPError.connectionFailed("SSE server did not provide endpoint URL")
        }
        ssePostEndpoint = postURL

        // 3. Start background SSE listener for server-to-client messages
        sseTask = Task { [weak self] in
            do {
                var evt = ""
                var buf = ""
                // Continue reading from the same byte stream
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }
                    if line.hasPrefix("event: ") {
                        evt = String(line.dropFirst(7))
                    } else if line.hasPrefix("data: ") {
                        buf += String(line.dropFirst(6))
                    } else if line.isEmpty && !buf.isEmpty {
                        await self?.processSSEData(buf)
                        evt = ""
                        buf = ""
                    }
                }
            } catch {
                print("[MCP-HTTP] SSE stream error for \(self?.serverName ?? "?"): \(error)")
            }
            // Stream ended — server disconnected
            await self?.handleSSEDisconnect()
        }

        // 4. Send MCP initialize via POST
        let initResult = try await sendSSERequest("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Executer", "version": "1.0"]
        ])

        isConnected = true
        reconnectAttempts = 0
        isReconnecting = false

        // 5. Send initialized notification
        sendSSENotification("notifications/initialized", params: [:])

        let name = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP-HTTP] Connected to \(name) via SSE")
    }

    /// Send a JSON-RPC request via SSE transport POST endpoint.
    /// Response comes back through the SSE stream (matched by ID).
    private func sendSSERequest(_ method: String, params: [String: Any],
                                timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard let postURL = ssePostEndpoint else { throw MCPError.disconnected }

        let id = nextId; nextId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]

        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        applyHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        // Fire the POST — response arrives via SSE stream
        let (data, response) = try await sseSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.httpError(statusCode: http.statusCode, body: body)
        }

        // Some SSE servers return the response directly in the POST body
        if !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["jsonrpc"] != nil {
            return extractResult(from: json)
        }

        // Otherwise wait for the response via SSE stream (continuation-based)
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = self.pendingRequests.removeValue(forKey: id) {
                    self.timeoutTasks.removeValue(forKey: id)
                    cont.resume(throwing: MCPError.timeout)
                }
            }
            self.timeoutTasks[id] = timeoutTask
        }
    }

    /// Fire-and-forget notification via SSE POST.
    private func sendSSENotification(_ method: String, params: [String: Any]) {
        guard let postURL = ssePostEndpoint else { return }
        Task {
            let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var request = URLRequest(url: postURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            applyHeaders(&request)
            request.httpBody = body
            _ = try? await sseSession.data(for: request)
        }
    }

    private func handleSSEDisconnect() {
        guard isConnected else { return }
        print("[MCP-HTTP] SSE stream ended for \(serverName)")
        disconnect()
        Task { await attemptReconnect() }
    }

    // MARK: - Unified Request Dispatch

    /// Route sendRequest to the correct transport.
    private func sendRequest(_ method: String, params: [String: Any],
                             timeout: TimeInterval = 15) async throws -> [String: Any] {
        switch mode {
        case .streamableHTTP:
            return try await sendStreamableHTTPRequest(method, params: params, timeout: timeout)
        case .sse:
            return try await sendSSERequest(method, params: params, timeout: timeout)
        }
    }

    // MARK: - SSE Parsing

    /// Parse an SSE byte stream for a specific JSON-RPC response ID.
    /// Used by Streamable HTTP when server returns text/event-stream.
    private func parseSSEForResponse(bytes: URLSession.AsyncBytes,
                                     expectedId: Int) async throws -> [String: Any] {
        var dataBuffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                dataBuffer += String(line.dropFirst(6))
            } else if line.isEmpty && !dataBuffer.isEmpty {
                if let data = dataBuffer.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let id = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue
                    if id == expectedId {
                        return extractResult(from: json)
                    }
                    // Not our response — could be a notification or different request's response
                    processJSONRPCMessage(json)
                }
                dataBuffer = ""
            }
        }
        throw MCPError.timeout
    }

    /// Process a data payload from SSE (background stream in SSE mode).
    private func processSSEData(_ data: String) {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        processJSONRPCMessage(json)
    }

    /// Route a JSON-RPC message to the correct pending continuation.
    private func processJSONRPCMessage(_ message: [String: Any]) {
        guard let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue,
              let cont = pendingRequests.removeValue(forKey: id) else { return }

        timeoutTasks.removeValue(forKey: id)?.cancel()

        if let error = message["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown MCP error"
            let code = error["code"] as? Int ?? -1
            cont.resume(throwing: MCPError.serverError(code: code, message: msg))
        } else {
            let result = message["result"] as? [String: Any] ?? [:]
            cont.resume(returning: result)
        }
    }

    // MARK: - Helpers

    /// Apply custom auth/headers to a URLRequest.
    private func applyHeaders(_ request: inout URLRequest) {
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
    }

    /// Extract the "result" field from a JSON-RPC response, or throw on error.
    private func extractResult(from json: [String: Any]) -> [String: Any] {
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown"
            let code = error["code"] as? Int ?? -1
            // Can't throw from here, so return error info in result
            return ["_error": true, "_code": code, "_message": msg]
        }
        return json["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Reconnection

    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        while reconnectAttempts < Self.maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts - 1)), Self.maxBackoffSeconds)
            print("[MCP-HTTP] Reconnecting \(serverName) in \(delay)s (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts))")

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connect()
                print("[MCP-HTTP] Reconnected \(serverName) successfully")
                return
            } catch {
                print("[MCP-HTTP] Reconnect \(serverName) attempt \(reconnectAttempts) failed: \(error.localizedDescription)")
            }
        }

        print("[MCP-HTTP] Giving up reconnecting \(serverName) after \(Self.maxReconnectAttempts) attempts")
    }
}
