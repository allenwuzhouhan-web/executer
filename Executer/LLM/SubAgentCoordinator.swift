import Foundation

/// Coordinates decomposition of complex tasks into parallel sub-agents.
/// Each sub-agent runs its own mini agent loop with isolated message history.
class SubAgentCoordinator {

    // MARK: - Types

    struct SubTask {
        let id: String
        let description: String
    }

    struct SubAgentResult {
        let taskId: String
        let description: String
        let result: String
    }

    // MARK: - Decomposition

    private static let decompositionPrompt = """
    Analyze this task and determine if it can be split into independent sub-tasks that can run in parallel.

    Rules:
    - Only split into TRULY independent sub-tasks (no step depends on another's result)
    - Each sub-task must be self-contained and completable on its own
    - 2-4 sub-tasks maximum
    - If the task is inherently sequential (each step needs the previous result), output: null

    If decomposable, output ONLY a JSON array like:
    [{"id": "1", "description": "..."}, {"id": "2", "description": "..."}]

    If NOT decomposable, output ONLY: null
    """

    /// Ask the LLM if the task can be decomposed into parallel sub-tasks.
    /// Returns nil if the task is sequential or decomposition isn't worthwhile.
    func decompose(
        command: String,
        manager: LLMServiceManager
    ) async -> [SubTask]? {
        let messages = [
            ChatMessage(role: "system", content: Self.decompositionPrompt),
            ChatMessage(role: "user", content: command)
        ]

        guard let response = try? await manager.currentService.sendChatRequest(
            messages: messages,
            tools: nil,
            maxTokens: 256
        ), let text = response.text else {
            return nil
        }

        // Parse JSON response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", trimmed.hasPrefix("[") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }

        let subTasks = array.compactMap { dict -> SubTask? in
            guard let id = dict["id"], let desc = dict["description"] else { return nil }
            return SubTask(id: id, description: desc)
        }

        // Only decompose if we got 2+ sub-tasks
        return subTasks.count >= 2 ? subTasks : nil
    }

    // MARK: - Parallel Execution

    /// Run sub-agents in parallel, each with their own mini agent loop.
    func executeSubAgents(
        subTasks: [SubTask],
        systemPrompt: String,
        manager: LLMServiceManager,
        registry: ToolRegistry,
        onProgress: @MainActor @escaping (String, Int, Int) -> Void
    ) async throws -> String {
        let results = await withTaskGroup(of: SubAgentResult.self) { group in
            for (index, task) in subTasks.enumerated() {
                group.addTask {
                    let result = await self.runSubAgent(
                        task: task,
                        systemPrompt: systemPrompt,
                        manager: manager,
                        registry: registry
                    )

                    await MainActor.run {
                        onProgress(task.description, index + 1, subTasks.count)
                    }

                    return result
                }
            }

            var collected: [SubAgentResult] = []
            collected.reserveCapacity(subTasks.count)
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.taskId < $1.taskId }
        }

        // If only one sub-agent had meaningful output, return it directly
        let nonEmpty = results.filter { !$0.result.isEmpty }
        if nonEmpty.count == 1 {
            return nonEmpty[0].result
        }

        // Merge results with a synthesis LLM call
        let mergeContent = results
            .map { "## Sub-task: \($0.description)\n\($0.result)" }
            .joined(separator: "\n\n")

        let mergeMessages = [
            ChatMessage(role: "system", content: "Merge these sub-task results into a single cohesive response. Be concise. Don't mention that sub-tasks were used."),
            ChatMessage(role: "user", content: mergeContent)
        ]

        if let mergeResponse = try? await manager.currentService.sendChatRequest(
            messages: mergeMessages,
            tools: nil,
            maxTokens: 2048
        ), let merged = mergeResponse.text {
            return merged
        }

        // Fallback: concatenate results
        return results.map { "**\($0.description):**\n\($0.result)" }.joined(separator: "\n\n")
    }

    // MARK: - Mini Agent Loop

    /// Run a single sub-agent with a focused mini agent loop (max 5 iterations).
    private func runSubAgent(
        task: SubTask,
        systemPrompt: String,
        manager: LLMServiceManager,
        registry: ToolRegistry
    ) async -> SubAgentResult {
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: task.description)
        ]

        let tools = registry.toolDefinitions()
        var finalText = ""

        for iteration in 0..<5 {
            if Task.isCancelled { break }

            guard let response = try? await manager.currentService.sendChatRequest(
                messages: messages,
                tools: tools,
                maxTokens: 2048
            ) else { break }

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? ""
                break
            }

            messages.append(response.rawMessage)

            // Execute tools (parallel for independent, sequential for UI)
            let results = await AgentLoop.executeToolCalls(
                toolCalls,
                registry: registry,
                iteration: iteration,
                maxIterations: 5,
                onStateChange: { _ in } // Sub-agents don't update main UI state
            )

            for r in results {
                messages.append(ChatMessage(
                    role: "tool",
                    content: r.result,
                    tool_call_id: r.callId
                ))
            }
        }

        return SubAgentResult(
            taskId: task.taskId,
            description: task.description,
            result: finalText
        )
    }
}

// MARK: - SubTask Extension

extension SubAgentCoordinator.SubTask {
    var taskId: String { id }
}
