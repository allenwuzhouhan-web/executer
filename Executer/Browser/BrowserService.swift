import Foundation

/// High-level typed API for browser automation via browser-use.
/// Manages the BrowserBridgeClient singleton and exposes clean async methods.
/// Follows the same pattern as WeChatService.
actor BrowserService {
    static let shared = BrowserService()

    private let bridgeClient = BrowserBridgeClient()
    private var started = false

    /// Whether the browser default is headless (invisible) or visible.
    var defaultHeadless: Bool {
        !UserDefaults.standard.bool(forKey: "browserDefaultVisible")
    }

    // MARK: - Lifecycle

    /// Ensures the bridge is running. Called automatically on first tool use.
    private func ensureStarted() async throws {
        let bridgeRunning = await bridgeClient.isRunning
        if started && bridgeRunning { return }

        // Determine which LLM provider/key to forward
        let provider = LLMServiceManager.shared.currentProvider
        let apiKey = APIKeyManager.shared.getKey(for: provider)

        let llmProvider: String
        switch provider {
        case .claude: llmProvider = "anthropic"
        case .deepseek: llmProvider = "deepseek"
        default: llmProvider = "openai" // Gemini/Kimi/MiniMax use OpenAI-compatible endpoints
        }

        try await bridgeClient.start(
            apiKey: apiKey,
            headless: defaultHeadless,
            llmProvider: llmProvider
        )
        started = true
    }

    func shutdown() async {
        await bridgeClient.stop()
        started = false
    }

    // MARK: - Browser Task

    /// Execute a multi-step browser task via natural language.
    func executeTask(task: String, url: String? = nil, visible: Bool? = nil, maxSteps: Int? = nil) async throws -> String {
        try await ensureStarted()

        var args: [String: Any] = ["task": task]
        if let url = url { args["url"] = url }
        if let visible = visible { args["visible"] = visible }
        if let maxSteps = maxSteps { args["max_steps"] = maxSteps }

        let result = try await bridgeClient.callTool(name: "browser_task", arguments: args)

        if result.isError {
            let errorText = extractText(from: result.content)
            throw BrowserBridgeClient.BridgeError.toolError(errorText)
        }

        let text = extractText(from: result.content)
        let steps = result.meta["steps"] as? Int
        if let steps = steps {
            return "\(text)\n\n[Completed in \(steps) browser steps]"
        }
        return text
    }

    // MARK: - Extract Data

    /// Extract structured data from a URL without a full agent loop.
    func extractData(url: String, instruction: String? = nil, selector: String? = nil) async throws -> String {
        try await ensureStarted()

        var args: [String: Any] = ["url": url]
        if let instruction = instruction { args["instruction"] = instruction }
        if let selector = selector { args["selector"] = selector }

        let result = try await bridgeClient.callTool(name: "browser_extract", arguments: args)

        if result.isError {
            let errorText = extractText(from: result.content)
            throw BrowserBridgeClient.BridgeError.toolError(errorText)
        }

        return extractText(from: result.content)
    }

    // MARK: - Screenshot

    /// Capture the browser's current view. Returns the file path.
    func screenshot() async throws -> String {
        try await ensureStarted()

        let result = try await bridgeClient.callTool(name: "browser_screenshot", arguments: [:])

        if result.isError {
            let errorText = extractText(from: result.content)
            throw BrowserBridgeClient.BridgeError.toolError(errorText)
        }

        return extractText(from: result.content)
    }

    // MARK: - Session Management

    /// Manage browser sessions: list tabs, close tab, toggle visible, close all.
    func manageSession(action: String, tabIndex: Int? = nil) async throws -> String {
        try await ensureStarted()

        var args: [String: Any] = ["action": action]
        if let tabIndex = tabIndex { args["tab_index"] = tabIndex }

        let result = try await bridgeClient.callTool(name: "browser_session", arguments: args)

        if result.isError {
            let errorText = extractText(from: result.content)
            throw BrowserBridgeClient.BridgeError.toolError(errorText)
        }

        return extractText(from: result.content)
    }

    // MARK: - Helpers

    private func extractText(from content: [[String: Any]]) -> String {
        content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }
}
