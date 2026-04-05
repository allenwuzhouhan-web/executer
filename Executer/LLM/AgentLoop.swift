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
        "browser_task": "Browsing web", "browser_extract": "Extracting web data",
        "browser_session": "Managing browser", "browser_screenshot": "Browser screenshot",
    ]

    // UI tools MUST execute sequentially — they depend on screen state
    private static let uiSequentialTools: Set<String> = [
        "click", "click_element", "type_text", "press_key", "hotkey",
        "scroll", "drag", "move_cursor", "launch_app", "select_all_text",
        "paste_text", "browser_click_element_css", "browser_type_in_element",
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

    // MARK: - Auto Skill Recording

    private static let skillFileLock = NSLock()

    private static func recordAutoSkill(command: String, messages: [ChatMessage], toolCallCount: Int) {
        // Extract tool call sequence from assistant messages
        var steps: [[String: String]] = []
        for msg in messages where msg.role == "assistant" {
            if let calls = msg.tool_calls {
                for call in calls {
                    steps.append(["tool": call.function.name])
                }
            }
        }

        guard steps.count >= 5 else { return }

        // Build auto-skill
        let keywords = command.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 }
            .prefix(5)

        // Deterministic name from command content (not hashValue which is per-process random)
        let cmdData = Data(command.utf8)
        let nameSlug = cmdData.prefix(16).map { String(format: "%02x", $0) }.joined().prefix(12)
        let skill: [String: Any] = [
            "name": "auto_\(nameSlug)",
            "description": "Auto-learned: \(String(command.prefix(100)))",
            "steps": steps.prefix(10).map { $0 },
            "trigger_keywords": Array(keywords),
            "created": ISO8601DateFormatter().string(from: Date()),
            "tool_count": toolCallCount,
        ]

        // Save to auto_skills.json (locked to prevent concurrent file corruption)
        let appSupport = URL.applicationSupportDirectory
        let skillFile = appSupport.appendingPathComponent("Executer/auto_skills.json")

        skillFileLock.lock()
        defer { skillFileLock.unlock() }

        var existing: [[String: Any]] = []
        if let data = try? Data(contentsOf: skillFile),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr
        }

        // Don't duplicate (check by description similarity)
        let desc = skill["description"] as? String ?? ""
        if existing.contains(where: { ($0["description"] as? String ?? "") == desc }) { return }

        existing.append(skill)
        // Keep max 50 auto-skills
        if existing.count > 50 { existing = Array(existing.suffix(50)) }

        if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted]) {
            try? data.write(to: skillFile)
            print("[Agent] Auto-skill recorded: \(skill["name"] ?? "?")")
        }
    }

    // MARK: - Document Task Detection

    private static func isDocumentCreationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let documentKeywords = [
            "ppt", "powerpoint", "presentation", "slide", "deck",
            "word", "docx", "document", "report", "essay", "memo", "letter",
            "excel", "xlsx", "spreadsheet", "table", "data sheet",
        ]
        return documentKeywords.contains { lower.contains($0) }
    }

    // MARK: - Complexity Classification

    static func classifyComplexity(_ command: String) -> TaskComplexity {
        let lower = command.lowercased()

        if lower.hasPrefix("[deep research]") { return .deep }
        if lower.hasPrefix("[browser visible]") || lower.hasPrefix("[browser background]") { return .complex }

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

        // Keep: system message (first), last 8 messages (most recent context), deduped
        let systemMessage = messages.first
        // Drop the first element from suffix if it duplicates the system message
        var recentMessages = Array(messages.suffix(8))
        if let sys = systemMessage, recentMessages.first?.role == sys.role && recentMessages.first?.content == sys.content {
            recentMessages.removeFirst()
        }
        messages = (systemMessage != nil ? [systemMessage!] : []) + recentMessages

        let newEstimate = messages.reduce(0) { $0 + (($1.content?.count ?? 0) / 4) }
        print("[Agent] Pruned context from ~\(estimatedTokens) to ~\(newEstimate) estimated tokens")
    }

    // MARK: - Tool Retry

    static func executeWithRetry(
        registry: ToolRegistry,
        toolName: String,
        arguments: String,
        maxRetries: Int = 1,
        trace: AgentTrace? = nil
    ) async -> String {
        for attempt in 0...maxRetries {
            do {
                return try await registry.execute(toolName: toolName, arguments: arguments)
            } catch {
                if attempt < maxRetries {
                    let backoff = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                    print("[Agent] Retry \(attempt + 1) for \(toolName): \(error.localizedDescription)")
                    trace?.append(TraceEntry(kind: .retry(
                        toolName: toolName,
                        attempt: attempt + 1,
                        reason: error.localizedDescription
                    )))
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
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        trace: AgentTrace? = nil
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
                    let batchResults = await executeParallelBatch(pendingBatch, registry: registry, trace: trace)
                    allResults.append(contentsOf: batchResults)
                    pendingBatch.removeAll()
                }

                // Execute UI tool sequentially
                let displayName = friendlyNames[call.function.name] ?? call.function.name
                print("[Agent] UI tool (sequential): \(call.function.name)")
                await MainActor.run {
                    onStateChange(.executing(toolName: displayName, step: iteration + 1, total: maxIterations))
                }

                let toolStart = CFAbsoluteTimeGetCurrent()
                let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments, trace: trace)
                let toolMs = (CFAbsoluteTimeGetCurrent() - toolStart) * 1000
                print("[Agent] Result: \(result)")
                let sanitized = InputSanitizer.frameToolResult(toolName: call.function.name, result: result)

                trace?.append(TraceEntry(kind: .toolCall(
                    name: call.function.name,
                    arguments: call.function.arguments,
                    result: result,
                    durationMs: toolMs,
                    success: !result.hasPrefix("Error")
                ), durationMs: toolMs))
                allResults.append(ToolResult(callId: call.id, toolName: call.function.name, result: sanitized))

                // Apply delay for UI tools (halved in speed mode)
                if let delay = toolDelays[call.function.name] {
                    let effectiveDelay = speedMode ? max(delay / 2, 30_000_000) : delay
                    try? await Task.sleep(nanoseconds: effectiveDelay)
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
            let batchResults = await executeParallelBatch(pendingBatch, registry: registry, trace: trace)
            allResults.append(contentsOf: batchResults)
        }

        return allResults
    }

    /// Execute a batch of independent tools in parallel using TaskGroup.
    static func executeParallelBatch(
        _ calls: [ToolCall],
        registry: ToolRegistry,
        trace: AgentTrace? = nil
    ) async -> [ToolResult] {
        if calls.count == 1 {
            // Single tool — no need for TaskGroup overhead
            let call = calls[0]
            print("[Agent] Tool call: \(call.function.name)")
            let toolStart = CFAbsoluteTimeGetCurrent()
            let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments, trace: trace)
            let toolMs = (CFAbsoluteTimeGetCurrent() - toolStart) * 1000
            print("[Agent] Result: \(result)")
            let sanitized = InputSanitizer.frameToolResult(toolName: call.function.name, result: result)
            trace?.append(TraceEntry(kind: .toolCall(
                name: call.function.name,
                arguments: call.function.arguments,
                result: result,
                durationMs: toolMs,
                success: !result.hasPrefix("Error")
            ), durationMs: toolMs))
            return [ToolResult(callId: call.id, toolName: call.function.name, result: sanitized)]
        }

        print("[Agent] Parallel batch: \(calls.map(\.function.name).joined(separator: ", "))")

        return await withTaskGroup(of: ToolResult.self) { group in
            for call in calls {
                group.addTask {
                    let toolStart = CFAbsoluteTimeGetCurrent()
                    let result = await executeWithRetry(registry: registry, toolName: call.function.name, arguments: call.function.arguments, trace: trace)
                    let toolMs = (CFAbsoluteTimeGetCurrent() - toolStart) * 1000
                    let sanitized = InputSanitizer.frameToolResult(toolName: call.function.name, result: result)
                    trace?.append(TraceEntry(kind: .toolCall(
                        name: call.function.name,
                        arguments: call.function.arguments,
                        result: result,
                        durationMs: toolMs,
                        success: !result.hasPrefix("Error")
                    ), durationMs: toolMs))
                    return ToolResult(callId: call.id, toolName: call.function.name, result: sanitized)
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
        agent: AgentProfile? = nil,
        resumeFromIteration: Int = 0,
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        onComplete: @MainActor @escaping (_ displayMessage: String, _ filteredText: String, _ messages: [ChatMessage], _ trace: AgentTrace?) -> Void,
        onError: @MainActor @escaping (_ message: String, _ trace: AgentTrace?) -> Void
    ) -> Task<Void, Never> {
        return Task.detached {
            let trace = AgentTrace(goal: fullCommand)
            let isResume = resumeFromIteration > 0
            do {
                let manager = LLMServiceManager.shared
                let registry = ToolRegistry.shared
                let context = SystemContext.current()

                // Route document creation commands to the document-specific provider if configured
                let isDocumentTask = Self.isDocumentCreationCommand(fullCommand)
                let service: LLMServiceProtocol = (isDocumentTask && manager.hasDocumentOverride)
                    ? manager.documentService
                    : manager.currentService

                // Transform browser choice prefix into LLM-friendly instruction
                var effectiveCommand = fullCommand
                if fullCommand.hasPrefix("[browser visible] ") {
                    let task = String(fullCommand.dropFirst("[browser visible] ".count))
                    effectiveCommand = "Use the browser_task tool with visible: true to do this: \(task)"
                } else if fullCommand.hasPrefix("[browser background] ") {
                    let task = String(fullCommand.dropFirst("[browser background] ".count))
                    effectiveCommand = "Use the browser_task tool with visible: false to do this: \(task)"
                }

                var tools: [[String: AnyCodable]]
                if let agent = agent {
                    tools = registry.filteredToolDefinitions(for: effectiveCommand, agent: agent)
                } else {
                    tools = registry.filteredToolDefinitions(for: effectiveCommand)
                }

                let complexity = Self.classifyComplexity(fullCommand)
                let maxIterations = complexity.maxIterations
                let maxTokens = agent?.maxTokenBudget ?? complexity.maxTokens

                print("[Agent] Complexity: \(complexity), maxIter: \(maxIterations), maxTokens: \(maxTokens)")

                // Build message chain — reuse previous for follow-ups
                let taskStartTime = CFAbsoluteTimeGetCurrent()

                var messages: [ChatMessage]
                if !previousMessages.isEmpty {
                    messages = previousMessages
                    messages.append(ChatMessage(role: "user", content: effectiveCommand))
                } else {
                    var systemPrompt = manager.fullSystemPrompt(context: context, query: effectiveCommand)
                    if let override = agent?.systemPromptOverride {
                        systemPrompt += "\n\n" + override
                    }
                    // Inject episode recall — past similar tasks
                    let episodeContext = EpisodeRecall.promptSection(forGoal: effectiveCommand)
                    if !episodeContext.isEmpty {
                        systemPrompt += episodeContext
                    }
                    // Inject learned rules from observation feedback loop
                    let rulesContext = LearningFeedbackLoop.promptSection()
                    if !rulesContext.isEmpty {
                        systemPrompt += rulesContext
                    }
                    messages = [
                        ChatMessage(role: "system", content: systemPrompt),
                        ChatMessage(role: "user", content: effectiveCommand)
                    ]
                }

                messages.reserveCapacity(messages.count + maxIterations * 3)

                // Persist session for crash recovery (unless resuming — session already exists)
                if !isResume {
                    await MainActor.run {
                        AgentSessionStore.shared.startSession(
                            command: resolvedCommand,
                            agentId: agent?.id ?? "general",
                            messages: messages
                        )
                    }
                }

                // Planning phase for complex tasks
                if complexity == .complex || complexity == .deep {
                    await MainActor.run {
                        onStateChange(.planning(summary: "Planning approach..."))
                    }

                    let planningMessages = [
                        ChatMessage(role: "system", content: Self.planningPrompt),
                        ChatMessage(role: "user", content: fullCommand)
                    ]

                    if let planResponse = try? await service.sendChatRequest(
                        messages: planningMessages,
                        tools: nil,
                        maxTokens: 512
                    ), let plan = planResponse.text {
                        print("[Agent] Plan: \(plan)")
                        trace.planOutput = plan
                        trace.append(TraceEntry(kind: .planning(output: plan)))
                        await MainActor.run {
                            onStateChange(.planning(summary: String(plan.prefix(200))))
                        }
                        // Inject plan as context for execution
                        messages.append(ChatMessage(role: "assistant", content: "My plan: \(plan)\n\nNow executing..."))
                    }
                }

                var finalText = "Done."

                // HostAgent decomposition: route complex tasks through AppAgents
                if complexity == .complex || complexity == .deep {
                    let coordinator = SubAgentCoordinator()
                    if let subTasks = await coordinator.decompose(command: fullCommand, manager: manager) {
                        print("[HostAgent] Decomposed into \(subTasks.count) AppAgents: \(subTasks.map { "\($0.id):\($0.targetApp ?? "general")" }.joined(separator: ", "))")
                        trace.append(TraceEntry(kind: .subAgentDecomposition(taskCount: subTasks.count)))
                        await MainActor.run {
                            onStateChange(.executing(toolName: "Routing \(subTasks.count) sub-agents", step: 0, total: subTasks.count))
                        }

                        if let mergedResult = try? await coordinator.executeSubAgents(
                            subTasks: subTasks,
                            systemPrompt: manager.fullSystemPrompt(context: context, query: fullCommand),
                            manager: manager,
                            registry: registry,
                            trace: trace,
                            onProgress: { desc, step, total in
                                onStateChange(.executing(toolName: String(desc.prefix(40)), step: step, total: total))
                            }
                        ) {
                            finalText = mergedResult
                            // Skip to post-processing
                            let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)
                            HandoffService.shared.saveHandoff(command: resolvedCommand, response: finalText, appContext: context.frontmostApp)
                            trace.finalOutcome = .success
                            trace.endTime = Date()
                            await MainActor.run {
                                AgentSessionStore.shared.complete(
                                    result: filteredText, messages: messages, trace: trace
                                )
                                onComplete(filteredText, filteredText, messages, trace)
                            }
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

                    let llmStart = CFAbsoluteTimeGetCurrent()
                    let response = try await service.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )
                    let llmMs = (CFAbsoluteTimeGetCurrent() - llmStart) * 1000

                    trace.append(TraceEntry(kind: .llmCall(
                        messageCount: messages.count,
                        responseLength: response.text?.count ?? 0,
                        hasToolCalls: response.toolCalls != nil && !(response.toolCalls?.isEmpty ?? true),
                        reasoning: response.rawMessage.reasoning_content
                    ), durationMs: llmMs))

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
                        onStateChange: onStateChange,
                        trace: trace
                    )

                    // Append results as tool messages
                    for r in results {
                        messages.append(ChatMessage(
                            role: "tool",
                            content: r.result,
                            tool_call_id: r.callId
                        ))
                    }

                    // Dynamic tool expansion: if request_tools was called, add requested tools to the tool set
                    for call in toolCalls where call.function.name == "request_tools" {
                        if let result = results.first(where: { $0.callId == call.id }),
                           result.result.contains("Available tools matching") {
                            // Parse tool names from the result and add their schemas
                            let lines = result.result.split(separator: "\n")
                            for line in lines where line.hasPrefix("- **") {
                                // Extract tool name from "- **tool_name**: description"
                                if let nameEnd = line.firstIndex(of: "*"),
                                   let nameStart = line.index(nameEnd, offsetBy: 2, limitedBy: line.endIndex) {
                                    let afterStars = line[nameStart...]
                                    if let closeStars = afterStars.firstIndex(of: "*") {
                                        let toolName = String(afterStars[..<closeStars])
                                        if let schemaArray = ToolRegistry.shared.singleToolSchema(toolName),
                                           let schema = schemaArray.first {
                                            // Add to current tool set if not already present
                                            if !tools.contains(where: { ($0["function"]?.value as? [String: AnyCodable])?["name"]?.value as? String == toolName }) {
                                                tools.append(schema)
                                                print("[AgentLoop] Dynamically added tool: \(toolName)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Checkpoint session to disk after each iteration (crash recovery)
                    await MainActor.run {
                        AgentSessionStore.shared.checkpoint(messages: messages, iteration: iteration)
                    }
                }

                // Apply personality post-filter before display
                let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)
                var displayMessage = filteredText

                // Save to handoff
                HandoffService.shared.saveHandoff(
                    command: resolvedCommand,
                    response: finalText,
                    appContext: context.frontmostApp
                )

                // Auto-skill creation: if 5+ tool calls succeeded, record as a reusable workflow
                let toolCallCount = messages.filter { $0.role == "tool" }.count
                if toolCallCount >= 5 {
                    Self.recordAutoSkill(
                        command: resolvedCommand,
                        messages: messages,
                        toolCallCount: toolCallCount
                    )
                }

                // Episode logging: record this task for future recall
                let taskDuration = CFAbsoluteTimeGetCurrent() - taskStartTime
                let hasError = finalText.lowercased().contains("error") || finalText.lowercased().contains("failed")
                EpisodeLogger.shared.record(
                    goal: resolvedCommand,
                    plan: nil,
                    messages: messages,
                    finalOutcome: hasError ? .failure : .success,
                    failureReason: hasError ? String(finalText.prefix(200)) : nil,
                    durationSeconds: taskDuration
                )

                // Post-task self-evaluation for complex/deep tasks (max 2 retries)
                if complexity == .complex || complexity == .deep {
                    let taskType = PostTaskEvaluator.classifyTaskType(fullCommand, messages: messages)
                    if case .general = taskType {
                        // Skip evaluation for general tasks
                    } else {
                        for retryAttempt in 0..<2 {
                            let evaluation = await PostTaskEvaluator.shared.evaluate(
                                goal: fullCommand, result: finalText, taskType: taskType
                            )
                            trace.append(TraceEntry(kind: .selfEvaluation(
                                passed: !evaluation.shouldRetry,
                                feedback: evaluation.feedback
                            )))
                            guard evaluation.shouldRetry else {
                                if !evaluation.passed && !evaluation.feedback.isEmpty {
                                    finalText += "\n\n[Self-check: \(evaluation.feedback)]"
                                }
                                break
                            }

                            print("[Agent] Self-evaluation failed (attempt \(retryAttempt + 1)): \(evaluation.feedback)")
                            await MainActor.run {
                                onStateChange(.executing(toolName: "Self-checking...", step: retryAttempt + 1, total: 2))
                            }

                            // Inject feedback and retry
                            messages.append(ChatMessage(role: "user", content: "Your output had issues: \(evaluation.feedback)\nPlease fix these issues."))

                            if let retryResponse = try? await service.sendChatRequest(
                                messages: messages, tools: tools, maxTokens: maxTokens
                            ) {
                                if let retryCalls = retryResponse.toolCalls, !retryCalls.isEmpty {
                                    messages.append(retryResponse.rawMessage)
                                    let retryResults = await Self.executeToolCalls(
                                        retryCalls, registry: registry,
                                        iteration: 0, maxIterations: 3,
                                        onStateChange: onStateChange,
                                        trace: trace
                                    )
                                    for r in retryResults {
                                        messages.append(ChatMessage(role: "tool", content: r.result, tool_call_id: r.callId))
                                    }
                                }
                                if let retryText = retryResponse.text, !retryText.isEmpty {
                                    finalText = retryText
                                }
                            }
                        }
                        // Re-apply personality filter after any retry
                        let refiltered = PersonalityEngine.shared.postFilterResponse(finalText)
                        displayMessage = refiltered
                    }
                }

                trace.finalOutcome = .success
                trace.endTime = Date()
                await MainActor.run {
                    AgentSessionStore.shared.complete(
                        result: filteredText,
                        richResultRaw: displayMessage != filteredText ? displayMessage : nil,
                        messages: messages,
                        trace: trace
                    )
                    AICursorManager.shared.stopAIControl()
                    onComplete(displayMessage, filteredText, messages, trace)
                }
            } catch {
                if Task.isCancelled {
                    trace.finalOutcome = .cancelled
                    trace.endTime = Date()
                    await MainActor.run {
                        AgentSessionStore.shared.cancel()
                    }
                    return
                }
                trace.finalOutcome = .failure(error.localizedDescription)
                trace.endTime = Date()
                trace.append(TraceEntry(kind: .error(
                    source: "AgentLoop",
                    message: error.localizedDescription
                )))
                await MainActor.run {
                    AgentSessionStore.shared.fail(error: error.localizedDescription, trace: trace)
                    AICursorManager.shared.stopAIControl()
                    onError(error.localizedDescription, trace)
                }
            }
        }
    }
}
