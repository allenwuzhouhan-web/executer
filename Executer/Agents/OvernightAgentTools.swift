import Foundation

/// LLM-callable tools for controlling the overnight agent.

struct StartOvernightAgentTool: ToolDefinition {
    let name = "start_overnight_agent"
    let description = "Start the autonomous overnight agent. It will discover tasks from email, calendar, reminders, and goals, then execute them while the user sleeps. Generates a morning report when done."

    let parameters: [String: Any] = JSONSchema.object(
        properties: [
            "hours": JSONSchema.number(description: "How many hours to run (default: until 7 AM)"),
        ]
    )

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let hours = optionalDouble("hours", from: args)

        let endTime: Date?
        if let h = hours {
            endTime = Date().addingTimeInterval(h * 3600)
        } else {
            endTime = nil  // Default: until 7 AM
        }

        await OvernightAgent.shared.activate(until: endTime)
        let status = await OvernightAgent.shared.statusDescription()
        return "Overnight agent activated.\n\(status)"
    }
}

struct OvernightAgentStatusTool: ToolDefinition {
    let name = "overnight_agent_status"
    let description = "Check the status of the overnight agent — whether it's running, what tasks are queued, and what has been completed."

    let parameters: [String: Any] = JSONSchema.object(properties: [:])

    func execute(arguments: String) async throws -> String {
        let status = await OvernightAgent.shared.statusDescription()
        let queue = OvernightTaskQueue.shared

        var lines = [status]

        let completed = queue.completedTasks()
        if !completed.isEmpty {
            lines.append("\nCompleted tasks:")
            for task in completed.suffix(5) {
                lines.append("  - \(task.title): \(task.result?.summary ?? "Done")")
            }
        }

        let pending = queue.pendingTasks()
        if !pending.isEmpty {
            lines.append("\nPending tasks:")
            for task in pending.prefix(5) {
                lines.append("  - \(task.title) [priority: \(String(format: "%.1f", task.priority))]")
            }
            if pending.count > 5 {
                lines.append("  ... and \(pending.count - 5) more")
            }
        }

        let needsReview = queue.needsReviewTasks()
        if !needsReview.isEmpty {
            lines.append("\nNeeds your review:")
            for task in needsReview {
                lines.append("  - \(task.title)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct AddOvernightTaskTool: ToolDefinition {
    let name = "add_overnight_task"
    let description = "Manually add a task to the overnight agent's queue. The agent will execute it during its next overnight session."

    let parameters: [String: Any] = JSONSchema.object(
        properties: [
            "title": JSONSchema.string(description: "Short title for the task"),
            "description": JSONSchema.string(description: "Detailed description of what needs to be done"),
            "priority": JSONSchema.number(description: "Priority 0.0 to 1.0 (default 0.5)"),
        ],
        required: ["title", "description"]
    )

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let description = try requiredString("description", from: args)
        let priority = optionalDouble("priority", from: args) ?? 0.5

        let task = OvernightTask(
            source: .manual,
            title: title,
            description: description,
            priority: min(max(priority, 0), 1),
            estimatedMinutes: 10
        )

        OvernightTaskQueue.shared.enqueue(task)
        return "Task added to overnight queue: '\(title)' (priority: \(String(format: "%.1f", priority))). Queue now has \(OvernightTaskQueue.shared.pendingTasks().count) pending tasks."
    }
}
