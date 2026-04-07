import Foundation

/// HostAgent-style coordinator inspired by Microsoft UFO.
/// Decomposes complex tasks into subtasks, routes each to an AppAgent
/// with scoped tools, and uses a TaskBlackboard for cross-agent data sharing.
///
/// For sequential tasks (most common): runs subtasks one-by-one so each AppAgent
/// can use results from prior steps via the blackboard.
/// For independent tasks: runs subtasks in parallel.
class SubAgentCoordinator {

    // MARK: - Types

    struct SubTask {
        let id: String
        let description: String
        let targetApp: String?       // which app this subtask targets
        let toolHints: [String]      // tool categories to prioritize
        let dependsOn: [String]      // IDs of subtasks that must complete first
        let hostMessage: String?     // tips from the HostAgent for this subtask
    }

    struct SubAgentResult {
        let taskId: String
        let description: String
        let result: String
        let success: Bool
    }

    let blackboard = TaskBlackboard()

    // MARK: - Decomposition (HostAgent Planning)

    private static let decompositionPrompt = """
    You are a HostAgent that plans multi-step tasks. Analyze this task and decompose it into subtasks.

    For EACH subtask, specify:
    - "id": unique string ID (e.g., "1", "2", "3")
    - "description": what to do (be specific and actionable)
    - "target_app": which macOS app this subtask needs (null if no specific app)
    - "tool_hints": relevant tool categories (e.g., "files", "web", "browser", "documents", "messaging", "terminal")
    - "depends_on": array of subtask IDs that must complete first (empty if independent)
    - "host_message": tips or context for the sub-agent executing this

    Rules:
    - 2-6 subtasks maximum
    - If steps need results from earlier steps, use depends_on to create a chain
    - If steps are independent, leave depends_on empty (they'll run in parallel)
    - Be specific about which app each step targets
    - If the task is too simple to decompose, output: null
    - NEVER add "web" or "browser" tool_hints for creation tasks (video, audio, documents, 3D models). These tools handle everything internally — no web search needed.

    Output ONLY a JSON array or null.
    """

    /// Ask the LLM to decompose the task into routed subtasks.
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
            maxTokens: 512
        ), let text = response.text else {
            return nil
        }

        // Parse JSON response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", trimmed.contains("[") else { return nil }

        // Extract JSON array
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]") else { return nil }
        let jsonStr = String(trimmed[start...end])

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let subTasks = array.compactMap { dict -> SubTask? in
            guard let id = dict["id"] as? String,
                  let desc = dict["description"] as? String else { return nil }
            return SubTask(
                id: id,
                description: desc,
                targetApp: dict["target_app"] as? String,
                toolHints: (dict["tool_hints"] as? [String]) ?? [],
                dependsOn: (dict["depends_on"] as? [String]) ?? [],
                hostMessage: dict["host_message"] as? String
            )
        }

        return subTasks.count >= 2 ? subTasks : nil
    }

    // MARK: - Execution (HostAgent Orchestration)

    /// Producer-consumer prefetch queue for pipelining tool inputs.
    /// Inspired by Flash Attention 3's warp-specialized producer-consumer pipelining:
    /// producers load data while consumers compute, fully overlapping data movement with execution.
    private actor PrefetchPipeline {
        private var prefetchedConfigs: [String: AppAgent.Config] = [:]

        /// Producer: pre-build the AppAgent config for an upcoming subtask.
        func prefetch(task: SubAgentCoordinator.SubTask) {
            let config = AppAgent.Config(
                subtaskId: task.id,
                subtaskDescription: task.description,
                targetApp: task.targetApp,
                toolHints: task.toolHints,
                maxIterations: 8,
                maxTokens: 2048,
                hostMessage: task.hostMessage
            )
            prefetchedConfigs[task.id] = config
        }

        /// Consumer: retrieve a pre-built config, or nil if not yet prefetched.
        func consume(taskId: String) -> AppAgent.Config? {
            return prefetchedConfigs.removeValue(forKey: taskId)
        }
    }

    private let prefetchPipeline = PrefetchPipeline()

    /// Execute subtasks respecting dependency ordering.
    /// Independent subtasks run in parallel; dependent ones run sequentially.
    ///
    /// Flash Attention 3-inspired producer-consumer pipelining:
    /// While current tasks execute (consumer), we prefetch configs for the next
    /// wave of ready tasks (producer), reducing inter-task setup latency.
    func executeSubAgents(
        subTasks: [SubTask],
        systemPrompt: String,
        manager: LLMServiceManager,
        registry: ToolRegistry,
        trace: AgentTrace? = nil,
        onProgress: @MainActor @escaping (String, Int, Int) -> Void
    ) async throws -> String {
        // Initialize blackboard with the plan
        let planEntries = subTasks.map { st in
            (id: st.id, description: st.description, targetApp: st.targetApp, toolHints: st.toolHints)
        }
        await blackboard.setPlan(
            goal: subTasks.map(\.description).joined(separator: "; "),
            subtasks: planEntries
        )

        trace?.append(TraceEntry(kind: .hostAgentRouting(
            subtaskCount: subTasks.count,
            apps: subTasks.compactMap(\.targetApp)
        )))

        // Build dependency graph
        let taskMap = Dictionary(uniqueKeysWithValues: subTasks.map { ($0.id, $0) })
        var completed = Set<String>()
        var results: [SubAgentResult] = []
        var stepIndex = 0

        // Producer: prefetch configs for initially ready tasks
        let initialReady = subTasks.filter { $0.dependsOn.isEmpty }
        for task in initialReady {
            await prefetchPipeline.prefetch(task: task)
        }

        // Execute in topological order with producer-consumer pipelining
        while completed.count < subTasks.count {
            // Find all tasks whose dependencies are satisfied
            let ready = subTasks.filter { task in
                !completed.contains(task.id) &&
                task.dependsOn.allSatisfy { completed.contains($0) }
            }

            guard !ready.isEmpty else {
                // Cycle or all remaining tasks have unsatisfied dependencies
                print("[HostAgent] No ready tasks — possible dependency cycle")
                break
            }

            // Producer: look ahead and prefetch configs for the NEXT wave of tasks
            // while the current wave executes (overlapping data prep with computation)
            let nextWaveCandidates = subTasks.filter { task in
                !completed.contains(task.id) &&
                !ready.contains(where: { $0.id == task.id }) &&
                task.dependsOn.allSatisfy { dep in
                    completed.contains(dep) || ready.contains(where: { $0.id == dep })
                }
            }
            for task in nextWaveCandidates {
                await prefetchPipeline.prefetch(task: task)
            }

            if ready.count == 1 {
                // Sequential execution
                let task = ready[0]
                stepIndex += 1
                await MainActor.run {
                    onProgress(task.targetApp ?? task.description, stepIndex, subTasks.count)
                }

                let result = await runAppAgent(
                    task: task,
                    service: manager.currentService,
                    registry: registry,
                    trace: trace
                )
                results.append(result)
                completed.insert(task.id)
            } else {
                // Parallel execution for independent tasks
                let batchResults = await withTaskGroup(of: SubAgentResult.self) { group in
                    for task in ready {
                        group.addTask {
                            await self.runAppAgent(
                                task: task,
                                service: manager.currentService,
                                registry: registry,
                                trace: trace
                            )
                        }
                    }
                    var collected: [SubAgentResult] = []
                    for await result in group {
                        stepIndex += 1
                        await MainActor.run {
                            onProgress(result.description, stepIndex, subTasks.count)
                        }
                        collected.append(result)
                    }
                    return collected
                }
                results.append(contentsOf: batchResults)
                for r in batchResults { completed.insert(r.taskId) }
            }
        }

        // Merge results
        return await mergeResults(results, manager: manager)
    }

    // MARK: - AppAgent Dispatch

    private func runAppAgent(
        task: SubTask,
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        trace: AgentTrace?
    ) async -> SubAgentResult {
        // Consumer: try to use pre-fetched config from the pipeline
        let config = await prefetchPipeline.consume(taskId: task.id) ?? AppAgent.Config(
            subtaskId: task.id,
            subtaskDescription: task.description,
            targetApp: task.targetApp,
            toolHints: task.toolHints,
            maxIterations: 8,
            maxTokens: 2048,
            hostMessage: task.hostMessage
        )

        let result = await AppAgent.execute(
            config: config,
            blackboard: blackboard,
            service: service,
            registry: registry,
            onStateChange: { _ in },  // Sub-agents use trace, not main UI state
            trace: trace
        )

        return SubAgentResult(
            taskId: result.subtaskId,
            description: task.description,
            result: result.output,
            success: result.success
        )
    }

    // MARK: - Result Merging

    private func mergeResults(_ results: [SubAgentResult], manager: LLMServiceManager) async -> String {
        let sorted = results.sorted { $0.taskId < $1.taskId }

        // If only one meaningful result, return it directly
        let nonEmpty = sorted.filter { !$0.result.isEmpty && $0.result != "Done." }
        if nonEmpty.count == 1 {
            return nonEmpty[0].result
        }

        // For multiple results, synthesize
        let mergeContent = sorted
            .map { "## \($0.description)\n\($0.result)" }
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

        // Fallback
        return sorted.map { "**\($0.description):**\n\($0.result)" }.joined(separator: "\n\n")
    }
}

// MARK: - SubTask Extension

extension SubAgentCoordinator.SubTask {
    var taskId: String { id }
}
