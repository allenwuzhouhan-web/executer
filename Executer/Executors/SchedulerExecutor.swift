import Foundation

// MARK: - Step 8: Scheduler Tools

struct ScheduleTaskTool: ToolDefinition {
    let name = "schedule_task"
    let description = "Schedule a command to run at a specific time or after a delay. The command will be processed through the normal LLM pipeline when it fires."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "command": JSONSchema.string(description: "The natural language command to execute when the task fires"),
            "run_at": JSONSchema.string(description: "ISO 8601 datetime to run the task (e.g. 2024-12-25T18:00:00). Use this OR delay_minutes."),
            "delay_minutes": JSONSchema.integer(description: "Number of minutes from now to run the task. Use this OR run_at.", minimum: 1, maximum: nil),
            "repeat_interval_minutes": JSONSchema.integer(description: "If set, repeat the task every N minutes after first execution", minimum: 1, maximum: nil),
            "label": JSONSchema.string(description: "Optional human-readable label for the task")
        ], required: ["command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let command = try requiredString("command", from: args)
        let runAtStr = optionalString("run_at", from: args)
        let delayMinutes = optionalInt("delay_minutes", from: args)
        let repeatInterval = optionalInt("repeat_interval_minutes", from: args)
        let label = optionalString("label", from: args)

        let scheduledDate: Date
        if let runAt = runAtStr {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: runAt) else {
                throw ExecuterError.invalidArguments("Invalid ISO 8601 date: \(runAt)")
            }
            scheduledDate = date
        } else if let minutes = delayMinutes {
            scheduledDate = Date().addingTimeInterval(Double(minutes) * 60)
        } else {
            throw ExecuterError.invalidArguments("Either run_at or delay_minutes is required")
        }

        let task = TaskScheduler.shared.addTask(
            command: command,
            scheduledDate: scheduledDate,
            repeatIntervalMinutes: repeatInterval,
            label: label
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: scheduledDate)

        var response = "Scheduled task '\(label ?? command.prefix(40).description)' for \(timeStr)."
        if let rep = repeatInterval {
            response += " Repeats every \(rep) minutes."
        }
        return response
    }
}

struct ListScheduledTasksTool: ToolDefinition {
    let name = "list_scheduled_tasks"
    let description = "List all pending scheduled tasks"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let pending = TaskScheduler.shared.pendingTasks()
        if pending.isEmpty {
            return "No pending scheduled tasks."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"

        let lines = pending.map { task -> String in
            let time = formatter.string(from: task.scheduledDate)
            let name = task.label ?? task.command.prefix(40).description
            let repeat_info = task.repeatIntervalMinutes.map { " (repeats every \($0)m)" } ?? ""
            return "- [\(time)] \(name)\(repeat_info)"
        }

        return "Pending tasks (\(pending.count)):\n\(lines.joined(separator: "\n"))"
    }
}
