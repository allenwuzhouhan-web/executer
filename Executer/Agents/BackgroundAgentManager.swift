import Foundation

/// Manages multiple concurrent background agent loops.
@MainActor
class BackgroundAgentManager: ObservableObject {
    static let shared = BackgroundAgentManager()

    @Published var agents: [BackgroundAgent] = []
    private let maxAgents = 5

    /// Path to the persistence file.
    private static var persistenceURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer")
        return dir.appendingPathComponent("background_agents.json")
    }

    private init() {
        loadFromDisk()
    }

    /// Start a new background agent.
    func startAgent(
        goal: String,
        trigger: BackgroundAgent.TriggerCondition,
        maxLifetimeMinutes: Int = 60
    ) -> BackgroundAgent? {
        guard agents.filter({ $0.state == .running }).count < maxAgents else {
            print("[BackgroundAgent] Max \(maxAgents) agents reached")
            return nil
        }

        var agent = BackgroundAgent(
            id: UUID(), goal: goal, trigger: trigger,
            state: .running, maxLifetimeMinutes: maxLifetimeMinutes,
            createdAt: Date(), lastCheckAt: nil, task: nil
        )

        let agentId = agent.id
        let task = Task.detached {
            await BackgroundAgentManager.shared.runAgentLoop(agentId: agentId)
        }
        agent.task = task
        agents.append(agent)
        saveToDisk()
        return agent
    }

    /// Stop a specific agent.
    func stopAgent(id: UUID) {
        guard let idx = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[idx].task?.cancel()
        agents[idx].state = .completed
        saveToDisk()
    }

    /// Stop all agents.
    func stopAll() {
        for i in agents.indices {
            agents[i].task?.cancel()
            agents[i].state = .completed
        }
        saveToDisk()
    }

    /// Active agent count.
    var activeCount: Int {
        agents.filter { $0.state == .running }.count
    }

    /// Spawn a subagent linked to a parent agent.
    @discardableResult
    func spawnSubAgent(
        parentId: UUID,
        goal: String,
        trigger: BackgroundAgent.TriggerCondition,
        maxLifetimeMinutes: Int = 30
    ) -> BackgroundAgent? {
        guard var agent = startAgent(goal: goal, trigger: trigger, maxLifetimeMinutes: maxLifetimeMinutes) else {
            return nil
        }
        // Link to parent
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx].parentAgentId = parentId
            agents[idx].appendLog("Spawned as subagent of \(parentId.uuidString.prefix(8))")
            agent = agents[idx]
        }
        // Log in parent
        if let parentIdx = agents.firstIndex(where: { $0.id == parentId }) {
            agents[parentIdx].appendLog("Spawned subagent \(agent.id.uuidString.prefix(8)): \(goal)")
        }
        saveToDisk()
        return agent
    }

    /// Get structured status for an agent.
    func getAgentStatus(id: UUID) -> AgentStatus? {
        guard let agent = agents.first(where: { $0.id == id }) else { return nil }
        let elapsed = Int(Date().timeIntervalSince(agent.createdAt) / 60)
        let subagents = agents.filter { $0.parentAgentId == id }
        return AgentStatus(
            id: agent.id,
            goal: agent.goal,
            state: agent.state.rawValue,
            elapsedMinutes: elapsed,
            progress: agent.progress,
            lastCheckAt: agent.lastCheckAt,
            recentLogs: Array(agent.logs.suffix(10)),
            result: agent.result,
            subagentIds: subagents.map { $0.id }
        )
    }

    /// Retrieve the result of a completed agent.
    func agentResult(id: UUID) -> String? {
        agents.first(where: { $0.id == id })?.result
    }

    /// Wait for an agent to complete (with timeout).
    func waitForAgent(id: UUID, timeoutSeconds: Int = 300) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if let agent = await MainActor.run(body: { agents.first(where: { $0.id == id }) }) {
                if agent.state != .running {
                    return agent.result ?? "Agent finished with state: \(agent.state.rawValue)"
                }
            } else {
                return nil
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2s
        }
        return "Timeout: agent still running after \(timeoutSeconds)s."
    }

    // MARK: - Agent Loop

    private func runAgentLoop(agentId: UUID) async {
        guard let agent = await MainActor.run(body: { agents.first(where: { $0.id == agentId }) }) else { return }
        let deadline = agent.createdAt.addingTimeInterval(Double(agent.maxLifetimeMinutes) * 60)

        while !Task.isCancelled && Date() < deadline {
            switch agent.trigger {
            case .poll(let interval, let check):
                await executePollCheck(agentId: agentId, check: check)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            case .webPageChange(let url):
                await checkWebPageChange(agentId: agentId, url: url)
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s

            case .fileChange(let path):
                await checkFileChange(agentId: agentId, path: path)
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s

            case .oneShot(let command):
                await executeOneShot(agentId: agentId, command: command)
                return
            }

            // Update last check time
            await MainActor.run {
                if let idx = self.agents.firstIndex(where: { $0.id == agentId }) {
                    self.agents[idx].lastCheckAt = Date()
                    self.saveToDisk()
                }
            }
        }

        // Expired
        await MainActor.run {
            if let idx = self.agents.firstIndex(where: { $0.id == agentId }) {
                self.agents[idx].state = .expired
                self.saveToDisk()
            }
        }
    }

    private func executePollCheck(agentId: UUID, check: String) async {
        appendLog(agentId: agentId, "Poll check started")
        let service = LLMServiceManager.shared.currentService
        let messages = [
            ChatMessage(role: "system", content: "You are a background monitor. Execute this check and report ONLY if the condition is met. If nothing notable, respond with exactly 'NO_CHANGE'."),
            ChatMessage(role: "user", content: check)
        ]

        let registry = ToolRegistry.shared
        let tools = registry.filteredToolDefinitions(for: check)

        guard let response = try? await service.sendChatRequest(
            messages: messages, tools: tools, maxTokens: 512
        ) else {
            appendLog(agentId: agentId, "LLM request failed")
            return
        }

        // If there are tool calls, execute them
        if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
            appendLog(agentId: agentId, "Executing \(toolCalls.count) tool(s): \(toolCalls.map(\.function.name).joined(separator: ", "))")
            var execMessages = messages
            execMessages.append(response.rawMessage)
            for call in toolCalls {
                let result = await AgentLoop.executeWithRetry(
                    registry: registry, toolName: call.function.name, arguments: call.function.arguments
                )
                execMessages.append(ChatMessage(role: "tool", content: result, tool_call_id: call.id))
            }
            // Get final assessment
            if let finalResponse = try? await service.sendChatRequest(
                messages: execMessages, tools: nil, maxTokens: 256
            ), let text = finalResponse.text, !text.contains("NO_CHANGE") {
                appendLog(agentId: agentId, "Change detected")
                await notifyUser(agentId: agentId, message: text)
            } else {
                appendLog(agentId: agentId, "No change")
            }
        } else if let text = response.text, !text.contains("NO_CHANGE") {
            appendLog(agentId: agentId, "Change detected (direct)")
            await notifyUser(agentId: agentId, message: text)
        } else {
            appendLog(agentId: agentId, "No change")
        }
    }

    private func checkWebPageChange(agentId: UUID, url: String) async {
        guard let fetchResult = try? await FetchURLContentTool().execute(
            arguments: "{\"url\": \"\(url)\", \"max_length\": 2000}"
        ) else { return }

        let cacheKey = "bg_web_\(agentId.uuidString)"
        let previous = UserDefaults.standard.string(forKey: cacheKey)
        UserDefaults.standard.set(fetchResult, forKey: cacheKey)

        if let previous = previous, previous != fetchResult {
            await notifyUser(agentId: agentId, message: "Web page changed at \(url)")
        }
    }

    private func checkFileChange(agentId: UUID, path: String) async {
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        let attrs = try? FileManager.default.attributesOfItem(atPath: expanded)
        let modDate = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "bg_file_\(agentId.uuidString)"
        let previous = UserDefaults.standard.double(forKey: cacheKey)
        UserDefaults.standard.set(modDate, forKey: cacheKey)

        if previous > 0 && modDate != previous {
            await notifyUser(agentId: agentId, message: "File changed: \(path)")
        }
    }

    private func executeOneShot(agentId: UUID, command: String) async {
        appendLog(agentId: agentId, "One-shot started: \(String(command.prefix(80)))")
        let service = LLMServiceManager.shared.currentService
        let context = SystemContext.current()
        let systemPrompt = LLMServiceManager.shared.fullSystemPrompt(context: context, query: command)

        var messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: command)
        ]
        let tools = ToolRegistry.shared.filteredToolDefinitions(for: command)
        var finalText: String?

        for step in 0..<10 {
            guard !Task.isCancelled else {
                appendLog(agentId: agentId, "Cancelled")
                return
            }
            // Update progress
            await MainActor.run {
                if let idx = self.agents.firstIndex(where: { $0.id == agentId }) {
                    self.agents[idx].progress = Double(step) / 10.0
                }
            }

            guard let response = try? await service.sendChatRequest(
                messages: messages, tools: tools, maxTokens: 2048
            ) else {
                appendLog(agentId: agentId, "LLM request failed at step \(step)")
                break
            }

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                if let text = response.text {
                    finalText = text
                    appendLog(agentId: agentId, "Completed with response")
                    await notifyUser(agentId: agentId, message: "Background task done: \(String(text.prefix(200)))")
                }
                break
            }

            appendLog(agentId: agentId, "Step \(step + 1): \(toolCalls.map(\.function.name).joined(separator: ", "))")
            messages.append(response.rawMessage)
            for call in toolCalls {
                let result = await AgentLoop.executeWithRetry(
                    registry: ToolRegistry.shared, toolName: call.function.name, arguments: call.function.arguments
                )
                messages.append(ChatMessage(role: "tool", content: result, tool_call_id: call.id))
            }
        }

        await MainActor.run {
            if let idx = self.agents.firstIndex(where: { $0.id == agentId }) {
                self.agents[idx].state = .completed
                self.agents[idx].result = finalText
                self.agents[idx].progress = 1.0
                self.saveToDisk()
            }
        }
    }

    // MARK: - Logging Helper

    private func appendLog(agentId: UUID, _ message: String) {
        if let idx = agents.firstIndex(where: { $0.id == agentId }) {
            agents[idx].appendLog(message)
        }
    }

    // MARK: - Disk Persistence

    /// Save all agents to disk (JSON). Called on every mutation.
    func saveToDisk() {
        let url = Self.persistenceURL
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(agents)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[BackgroundAgentManager] Failed to save agents: \(error)")
        }
    }

    /// Load agents from disk. Agents that were running are marked as pendingRestart.
    private func loadFromDisk() {
        let url = Self.persistenceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([BackgroundAgent].self, from: data)

            // Mark previously-running agents as needing restart
            for i in loaded.indices {
                if loaded[i].state == .running || loaded[i].state == .paused {
                    loaded[i].state = .pendingRestart
                    loaded[i].appendLog("App restarted — agent needs resume")
                }
                // task is always nil after deserialization
            }
            agents = loaded
        } catch {
            print("[BackgroundAgentManager] Failed to load agents: \(error)")
        }
    }

    /// Resume agents that were running before the app quit.
    /// Call this once after app launch (e.g., from AppDelegate).
    func resumePendingAgents() {
        for i in agents.indices where agents[i].state == .pendingRestart {
            let agent = agents[i]

            // Check if the agent has already expired based on its lifetime
            let deadline = agent.createdAt.addingTimeInterval(Double(agent.maxLifetimeMinutes) * 60)
            if Date() >= deadline {
                agents[i].state = .expired
                agents[i].appendLog("Expired while app was closed")
                continue
            }

            agents[i].state = .running
            agents[i].appendLog("Resumed after app restart")
            let agentId = agent.id
            let task = Task.detached {
                await BackgroundAgentManager.shared.runAgentLoop(agentId: agentId)
            }
            agents[i].task = task
        }
        saveToDisk()
    }

    // MARK: - User Notification

    private func notifyUser(agentId: UUID, message: String) async {
        let agent = await MainActor.run { agents.first(where: { $0.id == agentId }) }
        let title = String((agent?.goal ?? "Background Agent").prefix(50))
        let cleanMsg = message.prefix(200).replacingOccurrences(of: "\"", with: "'")

        _ = try? await ShowNotificationTool().execute(
            arguments: "{\"title\": \"BG: \(title)\", \"message\": \"\(cleanMsg)\"}"
        )
    }
}

// MARK: - Agent Status

struct AgentStatus {
    let id: UUID
    let goal: String
    let state: String
    let elapsedMinutes: Int
    let progress: Double
    let lastCheckAt: Date?
    let recentLogs: [BackgroundAgent.LogEntry]
    let result: String?
    let subagentIds: [UUID]

    var summary: String {
        var lines = ["\(goal) — \(state) (\(elapsedMinutes)m, \(Int(progress * 100))%)"]
        if !subagentIds.isEmpty {
            lines.append("  Subagents: \(subagentIds.map { String($0.uuidString.prefix(8)) }.joined(separator: ", "))")
        }
        if !recentLogs.isEmpty {
            lines.append("  Recent:")
            for log in recentLogs.suffix(5) {
                let time = log.timestamp.formatted(date: .omitted, time: .shortened)
                lines.append("    [\(time)] \(log.message)")
            }
        }
        if let result = result {
            lines.append("  Result: \(String(result.prefix(200)))")
        }
        return lines.joined(separator: "\n")
    }
}
