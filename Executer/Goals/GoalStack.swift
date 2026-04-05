import Foundation

/// Active, prioritized goal queue that the agent can autonomously work on.
/// Goals persist across sessions via JSON. Integrates with existing GoalTracker.
actor GoalStack {
    static let shared = GoalStack()

    private var goals: [ManagedGoal] = []
    private let maxGoals = 20

    /// Thread-safe cached prompt section, updated on every save.
    /// Accessible synchronously from any thread via the static accessor.
    private static var _cachedPromptSection: String = ""
    private static let promptLock = NSLock()

    /// Synchronous accessor for the cached prompt section (thread-safe).
    static var promptSection: String {
        promptLock.lock()
        defer { promptLock.unlock() }
        return _cachedPromptSection
    }

    init() {
        goals = Self.loadFromDisk()
        Self.promptLock.lock()
        Self._cachedPromptSection = buildPromptSection()
        Self.promptLock.unlock()
    }

    // MARK: - CRUD

    @discardableResult
    func addGoal(
        title: String,
        description: String,
        subGoals: [ManagedGoal.SubGoal] = [],
        priority: Double = 0.5,
        deadline: Date? = nil,
        source: ManagedGoal.GoalSource = .explicit
    ) -> ManagedGoal {
        let goal = ManagedGoal(
            id: UUID(), title: title, description: description,
            subGoals: subGoals, state: .pending, priority: priority,
            createdAt: Date(), updatedAt: Date(), deadline: deadline,
            source: source, failureHistory: []
        )
        goals.append(goal)
        goals.sort { $0.priority > $1.priority }
        if goals.count > maxGoals {
            goals = Array(goals.prefix(maxGoals))
        }
        saveToDisk()

        // Auto-decompose if no sub-goals provided
        if subGoals.isEmpty {
            let goalId = goal.id
            Task { await self.decomposeGoal(id: goalId) }
        }

        return goal
    }

    func activeGoals() -> [ManagedGoal] {
        goals.filter { $0.state == .active || $0.state == .pending }
    }

    func allGoals() -> [ManagedGoal] {
        goals
    }

    func completeSubGoal(goalId: UUID, subGoalId: UUID, result: String) {
        guard let gi = goals.firstIndex(where: { $0.id == goalId }),
              let si = goals[gi].subGoals.firstIndex(where: { $0.id == subGoalId }) else { return }
        goals[gi].subGoals[si].state = .completed
        goals[gi].subGoals[si].result = result
        goals[gi].updatedAt = Date()

        // Check if all sub-goals are complete
        if goals[gi].subGoals.allSatisfy({ $0.state == .completed }) {
            goals[gi].state = .completed
        }
        saveToDisk()
    }

    func failSubGoal(goalId: UUID, subGoalId: UUID, reason: String) {
        guard let gi = goals.firstIndex(where: { $0.id == goalId }),
              let si = goals[gi].subGoals.firstIndex(where: { $0.id == subGoalId }) else { return }
        goals[gi].subGoals[si].state = .failed
        goals[gi].subGoals[si].failureReason = reason
        goals[gi].failureHistory.append(ManagedGoal.FailureRecord(
            subGoalId: subGoalId, failureReason: reason,
            attemptedAt: Date(), alternativeUsed: nil
        ))
        goals[gi].updatedAt = Date()
        saveToDisk()
    }

    func removeGoal(id: UUID) {
        goals.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Replanning: when a sub-goal fails, ask LLM for alternative approach.
    func replanAfterFailure(goalId: UUID, failedSubGoalId: UUID) async -> ManagedGoal.SubGoal? {
        guard let gi = goals.firstIndex(where: { $0.id == goalId }),
              let si = goals[gi].subGoals.firstIndex(where: { $0.id == failedSubGoalId }) else { return nil }

        let goal = goals[gi]
        let failed = goal.subGoals[si]
        let failureContext = goal.failureHistory
            .filter { $0.subGoalId == failedSubGoalId }
            .map { "Failed: \($0.failureReason)" }
            .joined(separator: "\n")

        let prompt = """
        A sub-task failed. Suggest ONE alternative approach as a JSON object.
        Goal: \(goal.title)
        Failed step: \(failed.title)
        Failure history:\n\(failureContext)

        Output ONLY: {"title": "alternative step", "tool_hints": ["tool1", "tool2"]}
        """

        let messages = [
            ChatMessage(role: "system", content: "You are a task replanner. Output ONLY JSON."),
            ChatMessage(role: "user", content: prompt)
        ]

        let service = OpenAICompatibleService(provider: .deepseek, model: "deepseek-chat")
        guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 200),
              let text = response.text else { return nil }

        // Extract JSON from response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonStr: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonStr = String(trimmed[start...end])
        } else {
            return nil
        }

        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = parsed["title"] as? String else { return nil }

        let hints = (parsed["tool_hints"] as? [String]) ?? []
        let alternative = ManagedGoal.SubGoal(
            id: UUID(), title: title, state: .pending,
            dependencies: failed.dependencies, toolHints: hints,
            result: nil, failureReason: nil
        )

        // Insert alternative after the failed sub-goal
        goals[gi].subGoals.insert(alternative, at: si + 1)
        goals[gi].updatedAt = Date()
        saveToDisk()
        return alternative
    }

    // MARK: - Decomposition

    /// Auto-decompose a goal into sub-goals using LLM.
    private func decomposeGoal(id: UUID) async {
        guard let gi = goals.firstIndex(where: { $0.id == id }) else { return }
        let goal = goals[gi]

        let prompt = """
        Decompose this goal into 3-7 actionable sub-tasks. Output ONLY a JSON array.
        Goal: \(goal.title)
        Description: \(goal.description)

        Format: [{"title": "step description", "tool_hints": ["relevant_tool_names"], "depends_on": []}]
        depends_on contains 0-based indices of steps this depends on.
        """

        let messages = [
            ChatMessage(role: "system", content: "Decompose goals into sub-tasks. Output ONLY a JSON array."),
            ChatMessage(role: "user", content: prompt)
        ]

        let service = OpenAICompatibleService(provider: .deepseek, model: "deepseek-chat")
        guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 512),
              let text = response.text else { return }

        // Extract JSON array from response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonStr: String
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]") {
            jsonStr = String(trimmed[start...end])
        } else {
            return
        }

        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var subGoals: [ManagedGoal.SubGoal] = []
        var idMap: [Int: UUID] = [:]

        for (i, item) in parsed.enumerated() {
            let subId = UUID()
            idMap[i] = subId
            let deps = (item["depends_on"] as? [Int])?.compactMap { idMap[$0] } ?? []
            subGoals.append(ManagedGoal.SubGoal(
                id: subId,
                title: (item["title"] as? String) ?? "Step \(i + 1)",
                state: .pending,
                dependencies: deps,
                toolHints: (item["tool_hints"] as? [String]) ?? [],
                result: nil, failureReason: nil
            ))
        }

        guard let gi2 = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[gi2].subGoals = subGoals
        goals[gi2].state = .active
        goals[gi2].updatedAt = Date()
        saveToDisk()
        print("[GoalStack] Decomposed '\(goal.title)' into \(subGoals.count) sub-goals")
    }

    // MARK: - Prompt Section

    private func buildPromptSection() -> String {
        let active = activeGoals().prefix(5)
        guard !active.isEmpty else { return "" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        var lines = ["\n## Active Goals"]
        for goal in active {
            let progress = Int(goal.progress * 100)
            lines.append("- **\(goal.title)** [\(goal.state.rawValue), \(progress)% done]")
            if let next = goal.nextActionableSubGoal() {
                lines.append("  Next step: \(next.title)")
            }
            if let deadline = goal.deadline {
                lines.append("  Deadline: \(formatter.localizedString(for: deadline, relativeTo: Date()))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("goal_stack.json")
    }()

    private static func loadFromDisk() -> [ManagedGoal] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ManagedGoal].self, from: data)) ?? []
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(goals) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        Self.promptLock.lock()
        Self._cachedPromptSection = buildPromptSection()
        Self.promptLock.unlock()
    }
}
