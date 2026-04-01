import Foundation

/// JSON-RPC 2.0 client that communicates with the browser-use bridge over stdio.
/// Manages the subprocess lifecycle, request/response matching, and auto-restart.
/// Modeled on WeChatMCPClient — same patterns, adapted for browser automation.
actor BrowserBridgeClient {

    // MARK: - Types

    struct BridgeResult {
        let content: [[String: Any]]
        let isError: Bool
        let meta: [String: Any]
    }

    enum BridgeError: LocalizedError {
        case notRunning
        case serverCrashed(String)
        case timeout
        case invalidResponse(String)
        case toolError(String)
        case missingDependency(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Browser bridge is not running"
            case .serverCrashed(let msg): return "Browser bridge crashed: \(msg)"
            case .timeout: return "Browser bridge request timed out"
            case .invalidResponse(let msg): return "Invalid bridge response: \(msg)"
            case .toolError(let msg): return "Browser tool error: \(msg)"
            case .missingDependency(let msg): return "Missing dependency: \(msg)"
            }
        }
    }

    // MARK: - State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<BridgeResult, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var initialized = false

    /// Path to uv binary
    private let uvPath: String
    /// Path to browser_bridge.py script
    private let bridgeScriptPath: String

    /// Longer timeout for browser tasks (they involve page loads, agent loops, etc.)
    private let toolCallTimeout: TimeInterval = 60

    var isRunning: Bool {
        process?.isRunning == true && initialized
    }

    // MARK: - Init

    init(
        uvPath: String = "\(NSHomeDirectory())/.local/bin/uv",
        bridgeScriptPath: String? = nil
    ) {
        self.uvPath = uvPath
        // Default: look for browser_bridge.py next to the app bundle, or in a known location
        if let path = bridgeScriptPath {
            self.bridgeScriptPath = path
        } else {
            // Try bundle resource first, then fallback to app support
            if let bundlePath = Bundle.main.path(forResource: "browser_bridge", ofType: "py") {
                self.bridgeScriptPath = bundlePath
            } else {
                let appSupport = "\(NSHomeDirectory())/Library/Application Support/Executer"
                self.bridgeScriptPath = "\(appSupport)/browser_bridge.py"
            }
        }
    }

    // MARK: - Lifecycle

    func start(apiKey: String?, headless: Bool = true, llmProvider: String = "anthropic") async throws {
        // Don't double-start
        if process?.isRunning == true {
            if initialized { return }
            stop()
        }

        // Verify uv exists
        guard FileManager.default.fileExists(atPath: uvPath) else {
            throw BridgeError.missingDependency("uv not found at \(uvPath). Install with: curl -LsSf https://astral.sh/uv/install.sh | sh")
        }

        // Verify bridge script exists
        guard FileManager.default.fileExists(atPath: bridgeScriptPath) else {
            throw BridgeError.missingDependency("browser_bridge.py not found at \(bridgeScriptPath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = [
            "run",
            "--with", "browser-use",
            "--with", "playwright",
            "--with", "langchain-anthropic",
            "--with", "langchain-openai",
            bridgeScriptPath
        ]

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

        // Log stderr in background
        Task.detached {
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let line = String(data: data, encoding: .utf8) {
                    print("[BrowserBridge/stderr] \(line)", terminator: "")
                }
            }
        }

        try proc.run()
        print("[BrowserBridge] Bridge process started (pid: \(proc.processIdentifier))")

        // Start reading stdout in background
        readTask = Task { [weak self] in
            await self?.readLoop(pipe: stdout)
        }

        // Handshake: pass API key and preferences
        try await performHandshake(apiKey: apiKey, headless: headless, llmProvider: llmProvider)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            print("[BrowserBridge] Bridge stopped")
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        initialized = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BridgeError.notRunning)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Tool Calls

    func callTool(name: String, arguments: [String: Any]) async throws -> BridgeResult {
        if !isRunning {
            throw BridgeError.notRunning
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
                    cont.resume(throwing: BridgeError.timeout)
                }
            }
        }
    }

    private func removePendingRequest(id: Int) -> CheckedContinuation<BridgeResult, Error>? {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Handshake

    private func performHandshake(apiKey: String?, headless: Bool, llmProvider: String) async throws {
        let id = nextRequestId
        nextRequestId += 1

        var initParams: [String: Any] = [
            "headless": headless,
            "llm_provider": llmProvider,
        ]
        if let key = apiKey {
            initParams["api_key"] = key
        }

        let initMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": initParams
        ]

        // Send initialize and wait for response
        let _: BridgeResult = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            do {
                try sendMessage(initMsg)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            // 30s timeout for handshake (first run installs Playwright)
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let cont = await removePendingRequest(id: id) {
                    cont.resume(throwing: BridgeError.timeout)
                }
            }
        }

        initialized = true
        print("[BrowserBridge] Handshake complete — bridge ready (headless=\(headless))")
    }

    // MARK: - I/O

    private func sendMessage(_ message: [String: Any]) throws {
        guard let pipe = stdinPipe else {
            throw BridgeError.notRunning
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
            // Notification or progress update — log it
            if let method = json["method"] as? String {
                print("[BrowserBridge] Notification: \(method)")
            }
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            print("[BrowserBridge] Received response for unknown id: \(id)")
            return
        }

        // Check for JSON-RPC error
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            continuation.resume(throwing: BridgeError.toolError(message))
            return
        }

        // Parse result
        guard let result = json["result"] as? [String: Any] else {
            continuation.resume(throwing: BridgeError.invalidResponse("Missing result field"))
            return
        }

        let content = result["content"] as? [[String: Any]] ?? []
        let isError = result["isError"] as? Bool ?? false
        let meta = result["_meta"] as? [String: Any] ?? [:]
        continuation.resume(returning: BridgeResult(content: content, isError: isError, meta: meta))
    }

    private func handleTermination(exitCode: Int32) {
        print("[BrowserBridge] Bridge exited with code \(exitCode)")
        initialized = false

        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BridgeError.serverCrashed("Exit code \(exitCode)"))
        }
        pendingRequests.removeAll()
    }
}
