import Foundation

// MARK: - Start Background Agent

struct StartBackgroundAgentTool: ToolDefinition {
    let name = "start_background_agent"
    let description = """
        Start a background agent that monitors a condition while the user works. \
        Types: 'poll' (check something periodically), 'watch_file' (monitor file changes), \
        'watch_web' (monitor web page changes), 'run_background' (execute a task in background). \
        The agent will notify the user when the condition is met. Max 5 concurrent agents.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "goal": JSONSchema.string(description: "What to monitor (e.g., 'Check email for messages from boss')"),
            "type": JSONSchema.enumString(description: "Agent type", values: ["poll", "watch_file", "watch_web", "run_background"]),
            "target": JSONSchema.string(description: "URL for watch_web, file path for watch_file, check description for poll, command for run_background"),
            "interval_seconds": JSONSchema.integer(description: "Polling interval in seconds (default 60 for poll, 10 for file)", minimum: 5, maximum: 3600),
            "max_lifetime_minutes": JSONSchema.integer(description: "Maximum runtime in minutes (default 60, max 480)", minimum: 1, maximum: 480),
        ], required: ["goal", "type", "target"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let goal = try requiredString("goal", from: args)
        let type = try requiredString("type", from: args)
        let target = try requiredString("target", from: args)
        let interval = optionalInt("interval_seconds", from: args) ?? 60
        let lifetime = optionalInt("max_lifetime_minutes", from: args) ?? 60

        let trigger: BackgroundAgent.TriggerCondition
        switch type {
        case "poll": trigger = .poll(intervalSeconds: interval, check: target)
        case "watch_file": trigger = .fileChange(path: target)
        case "watch_web": trigger = .webPageChange(url: target)
        case "run_background": trigger = .oneShot(command: target)
        default: return "Unknown agent type: \(type). Use: poll, watch_file, watch_web, run_background."
        }

        let agent = await BackgroundAgentManager.shared.startAgent(
            goal: goal, trigger: trigger, maxLifetimeMinutes: lifetime
        )

        if let agent = agent {
            return "Background agent started (id: \(agent.id.uuidString.prefix(8))). Monitoring: \(goal). Max lifetime: \(lifetime) minutes."
        } else {
            return "Could not start agent. Maximum 5 concurrent background agents allowed."
        }
    }
}

// MARK: - List Background Agents

struct ListBackgroundAgentsTool: ToolDefinition {
    let name = "list_background_agents"
    let description = "List all background agents and their status."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let agents = await BackgroundAgentManager.shared.agents
        if agents.isEmpty { return "No background agents." }

        var lines = ["Background agents (\(agents.count)):"]
        for agent in agents {
            let elapsed = Int(Date().timeIntervalSince(agent.createdAt) / 60)
            let lastCheck = agent.lastCheckAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
            lines.append("- [\(agent.id.uuidString.prefix(8))] \(agent.goal) — \(agent.state.rawValue) (\(elapsed)m elapsed, last check: \(lastCheck))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Stop Background Agent

struct StopBackgroundAgentTool: ToolDefinition {
    let name = "stop_background_agent"
    let description = "Stop a specific background agent by its ID prefix (first 8 characters)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "agent_id": JSONSchema.string(description: "First 8 characters of the agent's UUID"),
        ], required: ["agent_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let idPrefix = try requiredString("agent_id", from: args).lowercased()

        let agents = await BackgroundAgentManager.shared.agents
        guard let agent = agents.first(where: { $0.id.uuidString.lowercased().hasPrefix(idPrefix) }) else {
            return "No agent found with ID starting with '\(idPrefix)'."
        }

        await BackgroundAgentManager.shared.stopAgent(id: agent.id)
        return "Stopped background agent: \(agent.goal)"
    }
}

// MARK: - Spawn Subagent

struct SpawnSubAgentTool: ToolDefinition {
    let name = "spawn_subagent"
    let description = """
        Spawn a child agent linked to a parent agent. The subagent runs independently in the background \
        and its result can be retrieved later with check_agent_status or wait_for_agent. \
        Use for parallelizing work — e.g., research subtask while main agent continues.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "parent_agent_id": JSONSchema.string(description: "ID prefix of the parent agent (8 chars)"),
            "goal": JSONSchema.string(description: "What the subagent should accomplish"),
            "command": JSONSchema.string(description: "Detailed instructions for the subagent"),
            "max_lifetime_minutes": JSONSchema.integer(description: "Max runtime (default 30, max 120)", minimum: 1, maximum: 120),
        ], required: ["parent_agent_id", "goal", "command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let parentPrefix = try requiredString("parent_agent_id", from: args).lowercased()
        let goal = try requiredString("goal", from: args)
        let command = try requiredString("command", from: args)
        let lifetime = optionalInt("max_lifetime_minutes", from: args) ?? 30

        let agents = await BackgroundAgentManager.shared.agents
        guard let parent = agents.first(where: { $0.id.uuidString.lowercased().hasPrefix(parentPrefix) }) else {
            return "No parent agent found with ID starting with '\(parentPrefix)'."
        }

        let sub = await BackgroundAgentManager.shared.spawnSubAgent(
            parentId: parent.id,
            goal: goal,
            trigger: .oneShot(command: command),
            maxLifetimeMinutes: lifetime
        )

        if let sub = sub {
            return "Subagent spawned (id: \(sub.id.uuidString.prefix(8))). Goal: \(goal). Max \(lifetime) minutes."
        }
        return "Could not spawn subagent — max agents reached."
    }
}

// MARK: - Check Agent Status

struct CheckAgentStatusTool: ToolDefinition {
    let name = "check_agent_status"
    let description = "Get detailed status of a background agent including logs, progress, and result."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "agent_id": JSONSchema.string(description: "ID prefix of the agent (8 chars)"),
        ], required: ["agent_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let idPrefix = try requiredString("agent_id", from: args).lowercased()

        let agents = await BackgroundAgentManager.shared.agents
        guard let agent = agents.first(where: { $0.id.uuidString.lowercased().hasPrefix(idPrefix) }) else {
            return "No agent found with ID starting with '\(idPrefix)'."
        }

        guard let status = await BackgroundAgentManager.shared.getAgentStatus(id: agent.id) else {
            return "Could not retrieve status."
        }
        return status.summary
    }
}

// MARK: - Wait For Agent

struct WaitForAgentTool: ToolDefinition {
    let name = "wait_for_agent"
    let description = "Block until a background agent completes, then return its result. Use with subagents to gather results."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "agent_id": JSONSchema.string(description: "ID prefix of the agent (8 chars)"),
            "timeout_seconds": JSONSchema.integer(description: "Max seconds to wait (default 300, max 600)", minimum: 5, maximum: 600),
        ], required: ["agent_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let idPrefix = try requiredString("agent_id", from: args).lowercased()
        let timeout = optionalInt("timeout_seconds", from: args) ?? 300

        let agents = await BackgroundAgentManager.shared.agents
        guard let agent = agents.first(where: { $0.id.uuidString.lowercased().hasPrefix(idPrefix) }) else {
            return "No agent found with ID starting with '\(idPrefix)'."
        }

        if agent.state != .running {
            return agent.result ?? "Agent already finished (\(agent.state.rawValue)). No result captured."
        }

        let result = await BackgroundAgentManager.shared.waitForAgent(id: agent.id, timeoutSeconds: timeout)
        return result ?? "Agent completed with no result."
    }
}
