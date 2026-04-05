import Foundation

/// The core see-think-act agent loop for autonomous computer control.
/// Two modes:
///   - Screen mode: perceive screen → reason → act → repeat (desktop apps)
///   - Browser-only mode: LLM uses browser DOM tools directly (web tasks, IXL)
class ComputerUseAgent {
    static let shared = ComputerUseAgent()

    // MARK: - Configuration

    struct Config {
        var maxIterations: Int = 50
        var perceptionMode: PerceptionMode = .axFirst
        var useVisionLLM: Bool = true
        var speedMode: Bool = false
        var toolAllowlist: Set<String>? = nil
        var systemPromptOverride: String? = nil
        /// Connect to user's real Chrome via CDP before starting browser loop.
        var cdpConnect: Bool = false
        /// URL pattern to select the right Chrome tab (e.g., "ixl.com").
        var cdpUrlPattern: String? = nil
    }

    enum PerceptionMode {
        case axOnly
        case axFirst
        case screenshotOnly
        case axPlusScreenshot
        case browserOnly
    }

    // MARK: - Working Memory

    private struct WorkingMemory {
        var actionsPerformed: [(action: String, result: String)] = []
        var lastPerception: VisionEngine.ScreenPerception?
        var stuckCount: Int = 0
        var lastActionDescription: String = ""

        mutating func addAction(action: String, result: String) {
            actionsPerformed.append((action, result))
            if actionsPerformed.count > 20 {
                actionsPerformed.removeFirst(actionsPerformed.count - 20)
            }
        }
    }

    // MARK: - State

    private var isRunning = false
    private var currentTask: Task<Void, Never>?
    private var workingMemory = WorkingMemory()

    // MARK: - System Prompts

    private static let screenModePrompt = """
    You are Executer in Computer Use mode. You can see the screen and control mouse/keyboard.

    Each turn you get the current screen state. WORKFLOW:
    1. Read screen state. 2. Decide action. 3. Call tool(s). 4. Observe next screen.

    RULES:
    - click_element for labeled targets, click with x,y for unlabeled.
    - Click field before typing. paste_text for text >2 chars.
    - 3 failed attempts → try alternative. When done → text response, no tools.
    """

    private static let browserModePrompt = """
    You are Executer in Browser mode. You control a Playwright browser via DOM tools ONLY.
    You CANNOT use mouse, keyboard, screenshots, or switch apps.

    Tools: browser_read_dom, browser_execute_js, browser_click_element_css, browser_type_in_element, browser_inspect_element, browser_get_console.

    RULES:
    - browser_read_dom to see the page. browser_click_element_css to click. browser_type_in_element to type.
    - browser_execute_js for complex queries. Batch multiple tools in ONE response. When done → text, no tools.
    """

    // MARK: - Public API

    func start(
        goal: String,
        config: Config = Config(),
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        onComplete: @MainActor @escaping (String) -> Void,
        onError: @MainActor @escaping (String) -> Void
    ) {
        guard !isRunning else {
            Task { @MainActor in onError("Computer Use Agent is already running.") }
            return
        }

        isRunning = true
        workingMemory = WorkingMemory()

        AICursorManager.shared.setStopCallback { [weak self] in
            self?.forceStop()
            Task { @MainActor in onComplete("Stopped by user.") }
        }
        AIControlBanner.shared.setStopAction { [weak self] in
            self?.forceStop()
            Task { @MainActor in onComplete("Stopped by user.") }
        }

        currentTask = Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                let result: String
                if config.perceptionMode == .browserOnly {
                    result = try await self.runBrowserLoop(goal: goal, config: config, onStateChange: onStateChange)
                } else {
                    result = try await self.runScreenLoop(goal: goal, config: config, onStateChange: onStateChange)
                }
                self.cleanup()
                await MainActor.run { onComplete(result) }
            } catch is CancellationError {
                self.cleanup()
                await MainActor.run { onComplete("Stopped.") }
            } catch {
                self.cleanup()
                await MainActor.run { onError("Error: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        forceStop()
    }

    private func forceStop() {
        currentTask?.cancel()
        currentTask = nil
        cleanup()
    }

    private func cleanup() {
        isRunning = false
        DispatchQueue.main.async {
            AICursorManager.shared.stopAIControl()
            AIControlBanner.shared.hide()
        }
    }

    // MARK: - Browser-Only Loop
    // Pure DOM interaction. No screen perception. No mouse. No keyboard.

    private func runBrowserLoop(
        goal: String,
        config: Config,
        onStateChange: @MainActor @escaping (InputBarState) -> Void
    ) async throws -> String {

        await MainActor.run {
            AIControlBanner.shared.show(message: "Browser agent running")
            onStateChange(.executing(toolName: "Working...", step: 1, total: config.maxIterations))
        }

        // CDP connection: connect to real Chrome before starting the loop
        if config.cdpConnect {
            await MainActor.run {
                onStateChange(.executing(toolName: "Connecting to Chrome...", step: 0, total: config.maxIterations))
            }

            let chromeReady = await ChromeCDPLauncher.ensureChromeWithCDP()
            if !chromeReady {
                return "Failed to launch Chrome with CDP. Please ensure Google Chrome is installed."
            }

            // Connect the browser bridge to real Chrome
            var connectArgs: [String: Any] = [:]
            if let pattern = config.cdpUrlPattern { connectArgs["url_pattern"] = pattern }
            let argsJSON = (try? String(data: JSONSerialization.data(withJSONObject: connectArgs), encoding: .utf8)) ?? "{}"

            do {
                let connectResult = try await BrowserService.shared.callBridgeTool(
                    name: "browser_connect_chrome",
                    arguments: argsJSON
                )
                print("[ComputerUse] CDP connected: \(connectResult.prefix(200))")
            } catch {
                return "Failed to connect to Chrome: \(error.localizedDescription)"
            }
        }

        let registry = ToolRegistry.shared
        let service = LLMServiceManager.shared.currentService

        var systemPrompt = Self.browserModePrompt
        if let override = config.systemPromptOverride {
            systemPrompt += "\n\n" + override
        }

        let tools: [[String: AnyCodable]]
        if let allowlist = config.toolAllowlist {
            tools = registry.filteredToolDefinitions(allowlist: allowlist)
        } else {
            tools = registry.filteredToolDefinitions(allowlist: [
                "browser_read_dom", "browser_execute_js", "browser_click_element_css",
                "browser_type_in_element", "browser_inspect_element", "browser_get_console",
            ])
        }

        let initialMessage = config.cdpConnect
            ? "Goal: \(goal)\n\nChrome is connected via CDP. Start by calling browser_read_elements to see what's on the page."
            : "Goal: \(goal)\n\nThe browser is open. Start by reading the page with browser_read_dom."

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: initialMessage)
        ]

        var finalText = "Completed."

        // Step 3: Main loop
        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { return "Cancelled." }

            await MainActor.run {
                let status = workingMemory.lastActionDescription.isEmpty
                    ? "Thinking... (\(iteration + 1))"
                    : "\(workingMemory.lastActionDescription) (\(iteration + 1))"
                onStateChange(.executing(toolName: status, step: iteration + 1, total: config.maxIterations))
                if iteration % 3 == 0 {
                    AIControlBanner.shared.updateStatus(status)
                }
            }

            pruneMessages(&messages, keepRecent: 16)

            // LLM call with timeout
            let response: LLMResponse
            do {
                response = try await withTimeout(seconds: 30) {
                    try await service.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: 2048
                    )
                }
            } catch {
                if Task.isCancelled { return "Cancelled." }
                // Timeout or error — retry once
                print("[ComputerUse] LLM call failed: \(error). Retrying...")
                do {
                    response = try await withTimeout(seconds: 30) {
                        try await service.sendChatRequest(
                            messages: messages,
                            tools: tools,
                            maxTokens: 2048
                        )
                    }
                } catch {
                    if Task.isCancelled { return "Cancelled." }
                    return "LLM not responding. Check your API key and internet connection."
                }
            }

            // No tool calls = done
            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? "Task completed."
                break
            }

            messages.append(response.rawMessage)

            // Execute browser tools sequentially (DOM state changes between calls)
            var consecutiveErrors = 0
            for call in toolCalls {
                if Task.isCancelled { return "Cancelled." }

                let result = await AgentLoop.executeWithRetry(
                    registry: registry,
                    toolName: call.function.name,
                    arguments: call.function.arguments
                )
                let sanitized = InputSanitizer.frameToolResult(toolName: call.function.name, result: result)
                messages.append(ChatMessage(role: "tool", content: sanitized, tool_call_id: call.id))
                workingMemory.addAction(action: call.function.name, result: String(result.prefix(400)))
                workingMemory.lastActionDescription = AgentLoop.friendlyName(for: call.function.name)

                // Track errors and inject hints
                let lower = result.lowercased()
                if lower.contains("error") || lower.contains("not found") || lower.contains("failed") || lower.contains("disabled") {
                    consecutiveErrors += 1
                } else {
                    consecutiveErrors = 0
                }
            }

            // If multiple tools failed, suggest debug action
            if consecutiveErrors >= 2 {
                messages.append(ChatMessage(role: "user", content:
                    "[HINT: Multiple tool errors. Call browser_page_state to diagnose, then browser_read_elements to re-scan the page.]"))
            }
        }

        return finalText
    }

    // MARK: - Timeout Helper

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    private struct TimeoutError: Error, LocalizedError {
        var errorDescription: String? { "Operation timed out" }
    }

    // MARK: - Screen Mode Loop (desktop apps, photo/video editing)

    private func runScreenLoop(
        goal: String,
        config: Config,
        onStateChange: @MainActor @escaping (InputBarState) -> Void
    ) async throws -> String {
        await MainActor.run {
            AICursorManager.shared.startAIControl()
            onStateChange(.executing(toolName: "Starting...", step: 0, total: config.maxIterations))
        }

        if config.speedMode { AgentLoop.speedMode = true }
        defer { AgentLoop.speedMode = false }

        let manager = LLMServiceManager.shared
        let registry = ToolRegistry.shared
        let service = manager.currentService
        let context = SystemContext.current()

        var systemPrompt = manager.fullSystemPrompt(context: context, query: goal)
        systemPrompt += "\n\n" + Self.screenModePrompt
        if let override = config.systemPromptOverride {
            systemPrompt += "\n\n" + override
        }

        let tools: [[String: AnyCodable]]
        if let allowlist = config.toolAllowlist {
            tools = registry.filteredToolDefinitions(allowlist: allowlist)
        } else {
            tools = registry.filteredToolDefinitions(allowlist: [
                "move_cursor", "click", "click_element", "scroll", "drag", "get_cursor_position",
                "type_text", "press_key", "hotkey", "select_all_text", "paste_text",
                "capture_screen", "ocr_image", "perceive_screen", "perceive_screen_visual", "find_element",
                "launch_app", "switch_to_app",
                "browser_task", "browser_extract", "browser_session", "browser_screenshot",
                "browser_execute_js", "browser_read_dom", "browser_get_console",
                "browser_inspect_element", "browser_click_element_css", "browser_type_in_element",
                "browser_intercept_network",
            ])
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: "Goal: \(goal)")
        ]

        let initialPerception = await VisionEngine.shared.perceive(forceScreenshot: config.perceptionMode == .screenshotOnly || config.perceptionMode == .axPlusScreenshot)
        messages.append(config.useVisionLLM
            ? VisionMessageBuilder.visionMessage(from: initialPerception)
            : VisionMessageBuilder.textMessage(from: initialPerception))
        workingMemory.lastPerception = initialPerception

        var finalText = "Completed."

        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { return "Cancelled." }

            await MainActor.run {
                let status = workingMemory.lastActionDescription.isEmpty ? "Thinking..." : workingMemory.lastActionDescription
                onStateChange(.executing(toolName: status, step: iteration + 1, total: config.maxIterations))
                if !config.speedMode || iteration % 5 == 0 {
                    AIControlBanner.shared.updateStatus(status)
                }
            }

            pruneMessages(&messages, keepRecent: 12)

            let response: LLMResponse
            do {
                response = try await withTimeout(seconds: 45) {
                    try await service.sendChatRequest(messages: messages, tools: tools, maxTokens: 4096)
                }
            } catch {
                if Task.isCancelled { return "Cancelled." }
                return "LLM not responding: \(error.localizedDescription)"
            }

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? "Task completed."
                break
            }

            messages.append(response.rawMessage)

            let results = await AgentLoop.executeToolCalls(
                toolCalls, registry: registry,
                iteration: iteration, maxIterations: config.maxIterations,
                onStateChange: onStateChange
            )

            for r in results {
                messages.append(ChatMessage(role: "tool", content: r.result, tool_call_id: r.callId))
                workingMemory.addAction(action: r.toolName, result: String(r.result.prefix(200)))
                workingMemory.lastActionDescription = AgentLoop.friendlyName(for: r.toolName)
            }

            // Verify action effect and get fresh perception
            let forceScreenshot = config.perceptionMode == .screenshotOnly || config.perceptionMode == .axPlusScreenshot
            VisionEngine.shared.invalidateCache() // Ensure fresh read after actions
            let newPerception = await VisionEngine.shared.perceive(forceScreenshot: forceScreenshot)

            if let last = workingMemory.lastPerception {
                // Detect app switch — critical context for the LLM
                if let lastPID = last.focusedPID, let newPID = newPerception.focusedPID, lastPID != newPID {
                    messages.append(ChatMessage(role: "user", content: "[App switched: \(last.appName) → \(newPerception.appName)]"))
                }

                if !VisionEngine.shared.detectChanges(from: last) {
                    messages.append(ChatMessage(role: "user", content: "[Screen unchanged]"))
                    workingMemory.stuckCount += 1
                } else {
                    messages.append(config.useVisionLLM
                        ? VisionMessageBuilder.visionMessage(from: newPerception)
                        : VisionMessageBuilder.textMessage(from: newPerception))
                    workingMemory.stuckCount = 0
                }
            } else {
                messages.append(config.useVisionLLM
                    ? VisionMessageBuilder.visionMessage(from: newPerception)
                    : VisionMessageBuilder.textMessage(from: newPerception))
            }
            workingMemory.lastPerception = newPerception

            if workingMemory.stuckCount >= 3 {
                messages.append(ChatMessage(role: "user", content: "[HINT: Screen unchanged 3x. Try different approach.]"))
                workingMemory.stuckCount = 0
            }
        }

        return finalText
    }

    // MARK: - Message Pruning

    private func pruneMessages(_ messages: inout [ChatMessage], keepRecent: Int) {
        let totalChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        guard totalChars / 4 > 80_000, messages.count > keepRecent + 2 else { return }
        let system = messages[0]
        let goal = messages[1]
        messages = [system, goal] + Array(messages.suffix(keepRecent))
    }
}

// MARK: - AgentLoop Extensions

extension AgentLoop {
    static var speedMode = false

    static func friendlyName(for toolName: String) -> String {
        let names: [String: String] = [
            "launch_app": "Opening app", "click": "Clicking", "click_element": "Clicking",
            "type_text": "Typing", "press_key": "Pressing key", "hotkey": "Shortcut",
            "scroll": "Scrolling", "move_cursor": "Moving cursor", "drag": "Dragging",
            "paste_text": "Pasting", "perceive_screen": "Reading screen",
            "browser_task": "Browsing", "browser_read_dom": "Reading page",
            "browser_execute_js": "Running JS", "browser_click_element_css": "Clicking",
            "browser_type_in_element": "Typing",
            "browser_connect_chrome": "Connecting to Chrome",
            "browser_read_elements": "Scanning page",
            "browser_click_element": "Clicking element",
            "browser_type_element": "Typing answer",
            "browser_page_state": "Checking page",
            "browser_wait_for": "Waiting",
            "browser_select_tab": "Switching tab",
        ]
        return names[toolName] ?? toolName.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
