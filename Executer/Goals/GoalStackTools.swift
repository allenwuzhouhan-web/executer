import Foundation

// MARK: - Add Goal

struct AddGoalTool: ToolDefinition {
    let name = "add_goal"
    let description = "Add a goal to the active goal stack. The agent will auto-decompose it into sub-tasks and track progress across sessions. Use for multi-step tasks the user wants tracked."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "Goal title (e.g., 'Prepare Monday presentation')"),
            "description": JSONSchema.string(description: "Detailed description of what needs to be done"),
            "priority": JSONSchema.number(description: "Priority 0.0 (low) to 1.0 (critical), default 0.5"),
            "deadline": JSONSchema.string(description: "ISO 8601 deadline (e.g., '2026-04-07T09:00:00Z'), optional"),
        ], required: ["title", "description"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let description = try requiredString("description", from: args)
        let priority = optionalDouble("priority", from: args) ?? 0.5

        var deadline: Date?
        if let deadlineStr = optionalString("deadline", from: args) {
            let formatter = ISO8601DateFormatter()
            deadline = formatter.date(from: deadlineStr)
        }

        let goal = await GoalStack.shared.addGoal(
            title: title, description: description,
            priority: priority, deadline: deadline,
            source: .explicit
        )

        return "Goal added: \"\(goal.title)\" (id: \(goal.id.uuidString.prefix(8))). Auto-decomposition in progress."
    }
}

// MARK: - List Goals

struct ListGoalsTool: ToolDefinition {
    let name = "list_goals"
    let description = "List all active goals and their progress, including sub-tasks and next actionable steps."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let goals = await GoalStack.shared.allGoals()
        if goals.isEmpty { return "No goals in the stack." }

        var lines = ["Goals (\(goals.count)):"]
        for goal in goals {
            let progress = Int(goal.progress * 100)
            let deadlineStr = goal.deadline.map { " | Deadline: \(ISO8601DateFormatter().string(from: $0))" } ?? ""
            lines.append("\n[\(goal.id.uuidString.prefix(8))] **\(goal.title)** — \(goal.state.rawValue), \(progress)% done\(deadlineStr)")

            for (i, sub) in goal.subGoals.enumerated() {
                let icon = sub.state == .completed ? "done" : sub.state == .failed ? "FAILED" : "pending"
                lines.append("  \(i + 1). [\(icon)] \(sub.title)")
                if let reason = sub.failureReason {
                    lines.append("     Failure: \(reason)")
                }
            }

            if let next = goal.nextActionableSubGoal() {
                lines.append("  -> Next: \(next.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Complete Goal Step

struct CompleteGoalStepTool: ToolDefinition {
    let name = "complete_goal_step"
    let description = "Mark a goal sub-task as completed with its result. Use the goal ID prefix and step number."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "goal_id": JSONSchema.string(description: "First 8 characters of the goal UUID"),
            "step_number": JSONSchema.integer(description: "1-based step number to mark complete"),
            "result": JSONSchema.string(description: "Result or output of the completed step"),
        ], required: ["goal_id", "step_number", "result"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let goalIdPrefix = try requiredString("goal_id", from: args).lowercased()
        let stepNum = optionalInt("step_number", from: args) ?? 1
        let result = try requiredString("result", from: args)

        let goals = await GoalStack.shared.allGoals()
        guard let goal = goals.first(where: { $0.id.uuidString.lowercased().hasPrefix(goalIdPrefix) }) else {
            return "No goal found with ID starting with '\(goalIdPrefix)'."
        }

        let stepIndex = stepNum - 1
        guard stepIndex >= 0, stepIndex < goal.subGoals.count else {
            return "Invalid step number \(stepNum). Goal has \(goal.subGoals.count) steps."
        }

        await GoalStack.shared.completeSubGoal(
            goalId: goal.id,
            subGoalId: goal.subGoals[stepIndex].id,
            result: result
        )

        let updatedGoals = await GoalStack.shared.allGoals()
        let updated = updatedGoals.first(where: { $0.id == goal.id })
        let progress = Int((updated?.progress ?? 0) * 100)
        return "Step \(stepNum) completed. Goal progress: \(progress)%."
    }
}

// MARK: - Get Next Goal Action

struct GetNextGoalActionTool: ToolDefinition {
    let name = "get_next_goal_action"
    let description = "Get the next actionable step for a goal. Returns the sub-task that should be worked on next (dependencies satisfied)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "goal_id": JSONSchema.string(description: "First 8 characters of the goal UUID. Omit to get from highest-priority goal."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let goalIdPrefix = optionalString("goal_id", from: args)?.lowercased()

        let goals = await GoalStack.shared.activeGoals()
        guard !goals.isEmpty else { return "No active goals." }

        let target: ManagedGoal
        if let prefix = goalIdPrefix {
            guard let g = goals.first(where: { $0.id.uuidString.lowercased().hasPrefix(prefix) }) else {
                return "No active goal found with ID starting with '\(prefix)'."
            }
            target = g
        } else {
            target = goals[0] // Highest priority
        }

        guard let next = target.nextActionableSubGoal() else {
            return "No actionable steps for '\(target.title)'. All steps are either completed, failed, or blocked."
        }

        let hints = next.toolHints.isEmpty ? "" : " (suggested tools: \(next.toolHints.joined(separator: ", ")))"
        return "Goal: \(target.title)\nNext step: \(next.title)\(hints)"
    }
}
