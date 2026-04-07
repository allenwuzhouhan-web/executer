import Foundation

/// When the AI encounters a novel task, decomposes it into steps using existing tools and caches the workflow.
actor ToolComposer {
    static let shared = ToolComposer()

    /// Plan a multi-tool workflow for a goal, checking cache first.
    func compose(goal: String) async -> CompositionPlan? {
        // Check cache first
        if let cached = CompositionCache.shared.findMatch(goal: goal) {
            print("[ToolComposer] Cache hit for: \(goal.prefix(60))")
            return CompositionPlan(
                goal: goal,
                steps: zip(cached.toolChain, cached.argumentTemplates).map {
                    CompositionStep(toolName: $0.0, argumentTemplate: $0.1, description: "")
                },
                fromCache: true
            )
        }

        // Plan via LLM
        return await planWithLLM(goal: goal)
    }

    /// Execute a composition plan step by step.
    func execute(plan: CompositionPlan) async -> CompositionResult {
        var results: [String] = []
        var toolsUsed: [String] = []
        var argTemplates: [String] = []

        for (i, step) in plan.steps.enumerated() {
            do {
                // Substitute previous results into argument template
                var args = step.argumentTemplate
                for (j, prevResult) in results.enumerated() {
                    args = args.replacingOccurrences(
                        of: "$RESULT_\(j)",
                        with: String(prevResult.prefix(500)).replacingOccurrences(of: "\"", with: "\\\"")
                    )
                }

                let result = try await ToolRegistry.shared.execute(
                    toolName: step.toolName,
                    arguments: args
                )
                results.append(result)
                toolsUsed.append(step.toolName)
                argTemplates.append(step.argumentTemplate)
                print("[ToolComposer] Step \(i + 1)/\(plan.steps.count): \(step.toolName) ✓")
            } catch {
                print("[ToolComposer] Step \(i + 1) failed: \(step.toolName) — \(error)")
                return CompositionResult(
                    success: false,
                    message: "Failed at step \(i + 1) (\(step.toolName)): \(error.localizedDescription)",
                    stepResults: results
                )
            }
        }

        // Cache successful composition
        if toolsUsed.count >= 2 {
            CompositionCache.shared.record(
                goal: plan.goal,
                toolChain: toolsUsed,
                argumentTemplates: argTemplates
            )
        }

        return CompositionResult(
            success: true,
            message: "Completed \(plan.steps.count) steps successfully",
            stepResults: results
        )
    }

    // MARK: - LLM Planning

    private func planWithLLM(goal: String) async -> CompositionPlan? {
        let allTools = ToolRegistry.shared.allToolNames()
        let toolList = allTools.prefix(100).joined(separator: ", ")

        let prompt = """
        Decompose this task into a sequence of tool calls:

        Task: \(goal)

        Available tools (subset): \(toolList)

        Output a JSON array of steps:
        ```json
        [
          {"tool": "tool_name", "args": "{...json arguments...}", "description": "what this step does"}
        ]
        ```

        Rules:
        - Use ONLY tools from the available list
        - Each step's args must be valid JSON for that tool
        - Use $RESULT_0, $RESULT_1 etc. to reference results from previous steps
        - Keep it minimal — fewest steps possible
        - Output ONLY the JSON array
        """

        do {
            let response = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 2048
            ).text ?? ""

            return parseCompositionPlan(goal: goal, response: response)
        } catch {
            print("[ToolComposer] LLM planning failed: \(error)")
            return nil
        }
    }

    private func parseCompositionPlan(goal: String, response: String) -> CompositionPlan? {
        guard let start = response.range(of: "["),
              let end = response.range(of: "]", options: .backwards) else { return nil }

        let jsonStr = String(response[start.lowerBound...end.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        let steps = array.compactMap { dict -> CompositionStep? in
            guard let tool = dict["tool"] as? String,
                  let args = dict["args"] as? String else { return nil }
            return CompositionStep(
                toolName: tool,
                argumentTemplate: args,
                description: dict["description"] as? String ?? ""
            )
        }

        guard !steps.isEmpty else { return nil }
        return CompositionPlan(goal: goal, steps: steps, fromCache: false)
    }
}

// MARK: - Models

struct CompositionPlan: Sendable {
    let goal: String
    let steps: [CompositionStep]
    let fromCache: Bool
}

struct CompositionStep: Sendable {
    let toolName: String
    let argumentTemplate: String
    let description: String
}

struct CompositionResult: Sendable {
    let success: Bool
    let message: String
    let stepResults: [String]
}
