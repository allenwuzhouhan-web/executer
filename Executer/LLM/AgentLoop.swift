import Foundation

/// Runs the multi-turn LLM agent loop: send messages, execute tool calls, repeat.
/// Supports parallel tool execution, adaptive complexity, planning, retry, and context pruning.
class AgentLoop {

    // MARK: - Task Complexity

    enum TaskComplexity {
        case simple   // 3 iterations, 1024 tokens
        case medium   // 8 iterations, 2048 tokens
        case complex  // 15 iterations, 4096 tokens
        case deep     // 25 iterations, 8192 tokens

        var maxIterations: Int {
            switch self {
            case .simple: return 3
            case .medium: return 8
            case .complex: return 15
            case .deep: return 25
            }
        }

        var maxTokens: Int {
            switch self {
            case .simple: return 1024
            case .medium: return 2048
            case .complex: return 4096
            case .deep: return 8192
            }
        }
    }

    // MARK: - Tool Result

    struct ToolResult {
        let callId: String
        let toolName: String
        let result: String
    }

    // MARK: - Static Constants

    private static let friendlyNames: [String: String] = [
        "launch_app": "Opening app", "quit_app": "Closing app",
        "click": "Clicking", "click_element": "Clicking",
        "type_text": "Typing", "press_key": "Pressing key",
        "hotkey": "Shortcut", "scroll": "Scrolling",
        "move_cursor": "Moving cursor", "drag": "Dragging",
        "capture_screen": "Looking", "ocr_image": "Reading screen",
        "open_url": "Opening URL", "open_url_in_safari": "Opening Safari",
        "search_web": "Searching", "dictionary_lookup": "Looking up",
        "music_play_song": "Playing", "music_pause": "Pausing",
    ]

    // UI tools MUST execute sequentially — they depend on screen state
    private static let uiSequentialTools: Set<String> = [
        "click", "click_element", "type_text", "press_key", "hotkey",
        "scroll", "drag", "move_cursor", "launch_app", "select_all_text",
    ]

    private static let toolDelays: [String: UInt64] = [
        "launch_app": 1_000_000_000,
        "click": 200_000_000, "click_element": 200_000_000,
        "type_text": 200_000_000, "press_key": 200_000_000,
        "hotkey": 200_000_000, "scroll": 200_000_000,
        "move_cursor": 200_000_000,
    ]

    private static let planningPrompt = """
    You are planning the execution of a complex task. Output a brief numbered plan (3-7 steps) of what tools you will call and in what order. Be specific about tool names. Do not execute anything yet — just plan. Keep it under 100 words.
    """

    // MARK: - Complexity Classification

    static func classifyComplexity(_ command: String) -> TaskComplexity {
        let lower = command.lowercased()

        if lower.hasPrefix("[deep research]") { return .deep }

        let complexIndicators = ["and then", "after that", "organize", "clean up",
                                 "research", "investigate", "compare", "analyze",
                                 "set up", "configure", "build", "create a"]
        let matchCount = complexIndicators.filter { lower.contains($0) }.count
        if matchCount >= 2 { return .complex }
        if matchCount == 1 && lower.count > 60 { return .complex }

        // Compound UI automation — multiple actions chained together
        let uiActions = ["click", "fullscreen", "type", "press", "scroll", "drag", "move cursor"]
        let conjunctions = [" and ", " then ", " after ", " next "]
        let hasUIAction = uiActions.contains(where: { lower.contains($0) })
        let hasConjunction = conjunctions.contains(where: { lower.contains($0) })
        if hasUIAction && hasConjunction { return .complex }
        if hasUIAction && lower.count > 30 { return .medium }

        let simpleIndicators = ["open ", "play ", "pause", "set volume", "mute",
                                "lock", "what time", "what's playing", "screenshot",
                                "dark mode", "light mode", "volume up", "volume down",
                                "brightness", "next", "previous", "skip", "shuffle"]
        if simpleIndicators.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            return .simple
        }

        return .medium
    }

    // MARK: - Context Pruning

    private static func pruneIfNeeded(_ messages: inout [ChatMessage], maxEstimatedTokens: Int = 100_000) {
        let estimatedTokens = messages.reduce(0) { $0 + (($1.content?.count ?? 0) / 4) }
        guard estimatedTokens > maxEstimatedTokens else { return }

        // Keep: system message (first), last 8 messages (most recent context)
        let systemMessage = messages.first
        let recentMessages = Array(messages.suffix(8))
        messages = (systemMessage != nil ? [systemMessage!] : []) + recentMessages

        let newEstimate = messages.reduce(0) { $0 + (($1.content?.count ?? 0) / 4) }
        print("[Agent] Pruned context from ~\(estimatedTokens) to ~\(newEstimate) estimated tokens")
    }

    // MARK: - Tool Retry

    static func executeWithRetry(
        registry: ToolRegistry,
        toolName: String,
        arguments: String,
        maxRetries: Int = 1
    ) async -> String {
        for attempt in 0...maxRetries {
            do {
                return try await registry.execute(toolName: toolName, arguments: arguments)
            } catch {
                if attempt < maxRetries {
                    let backoff = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                    print("[Agent] Retry \(attempt + 1) for \(toolName): \(error.localizedDescription)")
                    continue
                }
                return "Error after \(maxRetries + 1) attempts: \(error.localizedDescription)"
            }
        }
        return "Error: unexpected retry exit"
    }

    // MARK: - Parallel Tool Execution

    /// Execute tool calls with parallelism for independent tools, sequential for UI tools.
    static func executeToolCalls(
        _ toolCalls: [ToolCall],
        registry: ToolRegistry,
        iteration: Int,
        maxIterations: Int,
        onStateChange: @MainActor @escaping (InputBarState) -> Void
    ) async -> [ToolResult] {
        var allResults: [ToolResult] = []
        allResults.reserveCapacity(toolCalls.count)

        // Walk through calls, batching consecutive independent (non-UI) tools for parallel execution
        var pendingBatch: [ToolCall] = []

        for call in toolCalls {
            if Task.isCancelled { break }

            let isUITool = uiSequentialTools.contains(call.function.name)

            if isUITool {
                // Flush any pending parallel batch first
                if !pendingBatch.isEmpty {
                    let batchResults = await executeParallelBatch(pendingBatch, registry: registry)
                    allResults.append(contentsOf: batchResults)
                    pendingBatch.removeAll()
                }

                // Execute UI tool sequentially
                let displayName = friendlyNames[call.function.name] ?? call.function.name
                print("[Agent] UI tool (sequential): \(call.function.name)")
                await MainActor.run {
                    onStateChange(.executing(toolName: displayName, step: iteration + 1, total: maxIterations))
                }

                let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments)
                print("[Agent] Result: \(result)")
                allResults.append(ToolResult(callId: call.id, toolName: call.function.name, result: result))

                // Apply delay for UI tools
                if let delay = toolDelays[call.function.name] {
                    try? await Task.sleep(nanoseconds: delay)
                }
            } else {
                // Accumulate for parallel execution
                pendingBatch.append(call)
            }
        }

        // Flush remaining parallel batch
        if !pendingBatch.isEmpty {
            let batchDisplay = pendingBatch.count > 1
                ? "Running \(pendingBatch.count) tools in parallel"
                : friendlyNames[pendingBatch[0].function.name] ?? pendingBatch[0].function.name
            await MainActor.run {
                onStateChange(.executing(toolName: batchDisplay, step: iteration + 1, total: maxIterations))
            }
            let batchResults = await executeParallelBatch(pendingBatch, registry: registry)
            allResults.append(contentsOf: batchResults)
        }

        return allResults
    }

    /// Execute a batch of independent tools in parallel using TaskGroup.
    static func executeParallelBatch(
        _ calls: [ToolCall],
        registry: ToolRegistry
    ) async -> [ToolResult] {
        if calls.count == 1 {
            // Single tool — no need for TaskGroup overhead
            let call = calls[0]
            print("[Agent] Tool call: \(call.function.name)")
            let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments)
            print("[Agent] Result: \(result)")
            return [ToolResult(callId: call.id, toolName: call.function.name, result: result)]
        }

        print("[Agent] Parallel batch: \(calls.map(\.function.name).joined(separator: ", "))")

        return await withTaskGroup(of: ToolResult.self) { group in
            for call in calls {
                group.addTask {
                    let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments)
                    return ToolResult(callId: call.id, toolName: call.function.name, result: result)
                }
            }

            var collected: [ToolResult] = []
            collected.reserveCapacity(calls.count)
            for await r in group { collected.append(r) }

            // Return in original call order (not completion order) for correct message threading
            let orderMap = Dictionary(uniqueKeysWithValues: calls.enumerated().map { ($1.id, $0) })
            return collected.sorted { (orderMap[$0.callId] ?? 0) < (orderMap[$1.callId] ?? 0) }
        }
    }

    // MARK: - Main Execute

    func execute(
        fullCommand: String,
        resolvedCommand: String,
        previousMessages: [ChatMessage],
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        onComplete: @MainActor @escaping (_ displayMessage: String, _ filteredText: String, _ messages: [ChatMessage]) -> Void,
        onError: @MainActor @escaping (String) -> Void
    ) -> Task<Void, Never> {
        return Task.detached {
            do {
                let manager = LLMServiceManager.shared
                let registry = ToolRegistry.shared
                let context = SystemContext.current()
                let tools = registry.filteredToolDefinitions(for: fullCommand)

                let complexity = Self.classifyComplexity(fullCommand)
                let maxIterations = complexity.maxIterations
                let maxTokens = complexity.maxTokens

                print("[Agent] Complexity: \(complexity), maxIter: \(maxIterations), maxTokens: \(maxTokens)")

                // Build message chain — reuse previous for follow-ups
                var messages: [ChatMessage]
                if !previousMessages.isEmpty {
                    messages = previousMessages
                    messages.append(ChatMessage(role: "user", content: fullCommand))
                } else {
                    messages = [
                        ChatMessage(role: "system", content: manager.fullSystemPrompt(context: context, query: fullCommand)),
                        ChatMessage(role: "user", content: fullCommand)
                    ]
                }

                messages.reserveCapacity(messages.count + maxIterations * 3)

                // Planning phase for complex tasks
                if complexity == .complex || complexity == .deep {
                    await MainActor.run {
                        onStateChange(.planning(summary: "Planning approach..."))
                    }

                    let planningMessages = [
                        ChatMessage(role: "system", content: Self.planningPrompt),
                        ChatMessage(role: "user", content: fullCommand)
                    ]

                    if let planResponse = try? await manager.currentService.sendChatRequest(
                        messages: planningMessages,
                        tools: nil,
                        maxTokens: 512
                    ), let plan = planResponse.text {
                        print("[Agent] Plan: \(plan)")
                        await MainActor.run {
                            onStateChange(.planning(summary: String(plan.prefix(200))))
                        }
                        // Inject plan as context for execution
                        messages.append(ChatMessage(role: "assistant", content: "My plan: \(plan)\n\nNow executing..."))
                    }
                }

                var finalText = "Done."

                // Sub-agent decomposition for complex tasks
                if complexity == .complex || complexity == .deep {
                    let coordinator = SubAgentCoordinator()
                    if let subTasks = await coordinator.decompose(command: fullCommand, manager: manager) {
                        print("[Agent] Decomposed into \(subTasks.count) sub-agents")
                        await MainActor.run {
                            onStateChange(.executing(toolName: "Coordinating \(subTasks.count) sub-agents", step: 0, total: subTasks.count))
                        }

                        if let mergedResult = try? await coordinator.executeSubAgents(
                            subTasks: subTasks,
                            systemPrompt: manager.fullSystemPrompt(context: context, query: fullCommand),
                            manager: manager,
                            registry: registry,
                            onProgress: { desc, step, total in
                                onStateChange(.executing(toolName: String(desc.prefix(40)), step: step, total: total))
                            }
                        ) {
                            finalText = mergedResult
                            // Skip to post-processing
                            let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)
                            HandoffService.shared.saveHandoff(command: resolvedCommand, response: finalText, appContext: context.frontmostApp)
                            await MainActor.run { onComplete(filteredText, filteredText, messages) }
                            return
                        }
                        // If decomposition execution failed, fall through to normal agent loop
                    }
                }

                // Multi-turn agent loop with parallel tool execution
                for iteration in 0..<maxIterations {
                    if Task.isCancelled {
                        print("[Agent] Task cancelled at iteration \(iteration + 1)")
                        return
                    }

                    // Prune context if approaching token limit
                    Self.pruneIfNeeded(&messages)

                    print("[Agent] Iteration \(iteration + 1)/\(maxIterations) — \(messages.count) messages")

                    let response = try await manager.currentService.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )

                    guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                        finalText = response.text ?? "Done."
                        print("[Agent] Final response received (\(finalText.count) chars)")
                        break
                    }

                    // Append the assistant's message (contains tool_calls)
                    messages.append(response.rawMessage)

                    // Execute tools with parallel batching for independent tools
                    let results = await Self.executeToolCalls(
                        toolCalls,
                        registry: registry,
                        iteration: iteration,
                        maxIterations: maxIterations,
                        onStateChange: onStateChange
                    )

                    // Append results as tool messages
                    for r in results {
                        messages.append(ChatMessage(
                            role: "tool",
                            content: r.result,
                            tool_call_id: r.callId
                        ))
                    }
                }

                // Apply personality post-filter before display
                let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)
                let displayMessage = filteredText

                // Save to handoff
                HandoffService.shared.saveHandoff(
                    command: resolvedCommand,
                    response: finalText,
                    appContext: context.frontmostApp
                )

                await MainActor.run {
                    onComplete(displayMessage, filteredText, messages)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    onError(error.localizedDescription)
                }
            }
        }
    }
}
