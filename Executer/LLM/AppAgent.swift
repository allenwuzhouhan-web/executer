import Foundation

/// Per-app executor inspired by UFO's AppAgent.
/// Receives a scoped subtask + tool subset + blackboard context and runs
/// its own mini agent loop. The HostAgent spawns these for each subtask.
class AppAgent {

    // MARK: - Types

    struct Config {
        let subtaskId: String
        let subtaskDescription: String
        let targetApp: String?           // app name or bundle ID
        let toolHints: [String]          // tool categories to prioritize
        let maxIterations: Int
        let maxTokens: Int
        let hostMessage: String?         // tips from the HostAgent

        static let `default` = Config(
            subtaskId: "0",
            subtaskDescription: "",
            targetApp: nil,
            toolHints: [],
            maxIterations: 8,
            maxTokens: 2048,
            hostMessage: nil
        )
    }

    struct Result {
        let subtaskId: String
        let output: String
        let sharedData: [String: String]   // data to publish to blackboard
        let toolsUsed: [String]
        let success: Bool
    }

    // MARK: - App-specific tool scoping

    /// Maps app names/categories to the tool categories most relevant for that app.
    private static let appToolMapping: [String: [ToolCategory]] = [
        // Productivity apps
        "Pages": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Numbers": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Keynote": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft Word": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft Excel": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "Microsoft PowerPoint": [.files, .fileContent, .documents, .clipboard, .keyboard, .cursor],
        "TextEdit": [.files, .fileContent, .clipboard, .keyboard, .cursor],
        "Notes": [.productivity, .clipboard, .keyboard, .cursor],

        // Browsers
        "Safari": [.web, .webContent, .browser, .clipboard],
        "Google Chrome": [.web, .webContent, .browser, .clipboard],
        "Arc": [.web, .webContent, .browser, .clipboard],
        "Firefox": [.web, .webContent, .browser, .clipboard],

        // Communication
        "Messages": [.messaging, .clipboard],
        "WeChat": [.messaging, .clipboard],
        "Mail": [.productivity, .clipboard, .keyboard, .cursor],
        "Slack": [.messaging, .clipboard, .keyboard, .cursor],

        // Dev tools
        "Terminal": [.terminal, .files, .fileContent, .fileSearch],
        "Xcode": [.terminal, .files, .fileContent, .fileSearch, .clipboard],
        "Visual Studio Code": [.terminal, .files, .fileContent, .fileSearch, .clipboard],

        // System
        "Finder": [.files, .fileSearch, .windows],
        "System Preferences": [.systemSettings],
        "System Settings": [.systemSettings],
    ]

    /// Common tools always available regardless of app context.
    private static let commonCategories: [ToolCategory] = [
        .appControl, .clipboard, .notifications, .memory, .screenshot
    ]

    // MARK: - Execution

    /// Run the AppAgent's scoped agent loop for a single subtask.
    static func execute(
        config: Config,
        blackboard: TaskBlackboard,
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        trace: AgentTrace? = nil
    ) async -> Result {
        let startTime = CFAbsoluteTimeGetCurrent()
        var toolsUsed: [String] = []
        var sharedDataCollected: [String: String] = [:]

        // 1. Get blackboard context for this subtask
        let blackboardContext = await blackboard.contextForSubTask(id: config.subtaskId)
        await blackboard.markRunning(id: config.subtaskId)

        // 2. Scope tools to the target app
        let tools = scopeTools(
            targetApp: config.targetApp,
            toolHints: config.toolHints,
            registry: registry
        )

        // 3. Build system prompt with app-specific context
        let systemPrompt = buildSystemPrompt(config: config, blackboardContext: blackboardContext)

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: config.subtaskDescription)
        ]

        var finalText = ""

        // 4. Mini agent loop
        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { break }

            await MainActor.run {
                let label = config.targetApp ?? "Sub-agent"
                onStateChange(.executing(
                    toolName: "\(label): step \(iteration + 1)",
                    step: iteration + 1,
                    total: config.maxIterations
                ))
            }

            guard let response = try? await service.sendChatRequest(
                messages: messages,
                tools: tools,
                maxTokens: config.maxTokens
            ) else {
                finalText = "Error: LLM request failed"
                break
            }

            trace?.append(TraceEntry(kind: .llmCall(
                messageCount: messages.count,
                responseLength: response.text?.count ?? 0,
                hasToolCalls: response.toolCalls != nil && !(response.toolCalls?.isEmpty ?? true),
                reasoning: response.rawMessage.reasoning_content
            )))

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? "Done."
                break
            }

            messages.append(response.rawMessage)

            // Execute tools
            let results = await AgentLoop.executeToolCalls(
                toolCalls,
                registry: registry,
                iteration: iteration,
                maxIterations: config.maxIterations,
                onStateChange: onStateChange,
                trace: trace
            )

            for r in results {
                messages.append(ChatMessage(
                    role: "tool",
                    content: r.result,
                    tool_call_id: r.callId
                ))
                toolsUsed.append(r.toolName)

                // Auto-detect shared data from tool results (clipboard, file paths, etc.)
                extractSharedData(toolName: r.toolName, result: r.result, into: &sharedDataCollected)
            }

            // Record trajectory on blackboard
            for call in toolCalls {
                let resultText = results.first(where: { $0.callId == call.id })?.result ?? ""
                await blackboard.recordAction(
                    agent: config.targetApp ?? "app_agent",
                    action: call.function.name,
                    result: String(resultText.prefix(200))
                )
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let success = !finalText.lowercased().contains("error")

        // 5. Update blackboard with results
        if success {
            await blackboard.completeSubTask(
                id: config.subtaskId,
                result: finalText,
                sharedData: sharedDataCollected
            )
        } else {
            await blackboard.failSubTask(id: config.subtaskId, reason: finalText)
        }

        trace?.append(TraceEntry(kind: .subAgentComplete(
            id: config.subtaskId,
            app: config.targetApp,
            durationMs: duration * 1000,
            success: success
        )))

        print("[AppAgent] \(config.targetApp ?? "agent") completed in \(String(format: "%.1f", duration))s — \(toolsUsed.count) tool calls")

        return Result(
            subtaskId: config.subtaskId,
            output: finalText,
            sharedData: sharedDataCollected,
            toolsUsed: toolsUsed,
            success: success
        )
    }

    // MARK: - Tool Scoping

    /// Returns tool schemas scoped to the target application.
    private static func scopeTools(
        targetApp: String?,
        toolHints: [String],
        registry: ToolRegistry
    ) -> [[String: AnyCodable]] {
        var categories = Set(commonCategories)

        // Add app-specific categories
        if let app = targetApp, let appCats = appToolMapping[app] {
            categories.formUnion(appCats)
        }

        // Add categories from tool hints
        for hint in toolHints {
            if let cat = ToolCategory(rawValue: hint) {
                categories.insert(cat)
            }
        }

        // If no specific app, give a broad set
        if targetApp == nil {
            categories.formUnion([.files, .fileContent, .web, .webContent, .terminal, .keyboard, .cursor])
        }

        let schemas = registry.filteredToolDefinitions(categories: categories)
        print("[AppAgent] Scoped to \(schemas.count) tools for \(targetApp ?? "general")")
        return schemas
    }

    // MARK: - System Prompt

    private static func buildSystemPrompt(config: Config, blackboardContext: String) -> String {
        var prompt = """
        You are an AppAgent — a focused executor for a specific subtask. \
        Complete your assigned subtask efficiently using the available tools. \
        Do not attempt work outside your subtask scope.

        \(blackboardContext)
        """

        if let app = config.targetApp {
            prompt += "\n\nYou are working in \(app). Use tools appropriate for this application."
        }

        if let hostMsg = config.hostMessage {
            prompt += "\n\nHost agent tips: \(hostMsg)"
        }

        return prompt
    }

    // MARK: - Shared Data Extraction

    /// Auto-detect useful data from tool results to share via blackboard.
    private static func extractSharedData(toolName: String, result: String, into data: inout [String: String]) {
        switch toolName {
        case "get_clipboard_text", "set_clipboard_text":
            if result.count < 2000 {
                data["clipboard_content"] = result
            }
        case "read_file", "read_document":
            // Store file content preview for downstream agents
            data["last_read_content"] = String(result.prefix(1000))
        case "find_files":
            data["found_files"] = result
        case "browser_extract", "browser_task":
            data["browser_result"] = String(result.prefix(1500))
        case "capture_screen", "capture_window":
            data["last_screenshot_path"] = result
        case "search_web", "instant_search":
            data["search_results"] = String(result.prefix(1500))
        default:
            break
        }
    }
}
