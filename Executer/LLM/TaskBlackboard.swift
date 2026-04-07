import Foundation

/// Session-scoped shared state for cross-app task coordination.
/// Inspired by UFO's Blackboard pattern — accumulates subtask results,
/// shared data, and context so sub-agents can share information across app boundaries.
///
/// The HostAgent writes the plan and monitors progress.
/// AppAgents read their subtask, write their results, and read shared data from prior steps.
actor TaskBlackboard {

    // MARK: - Types

    struct SubTaskEntry: Sendable {
        let id: String
        let description: String
        let targetApp: String?          // bundle ID or app name
        let toolHints: [String]         // suggested tool categories
        var status: SubTaskStatus
        var result: String?
        var sharedData: [String: String] // key-value pairs other agents can read
        let startTime: Date
        var endTime: Date?
    }

    enum SubTaskStatus: String, Sendable {
        case pending, running, completed, failed
    }

    struct PlanSnapshot: Sendable {
        let goal: String
        let subtasks: [SubTaskEntry]
        let createdAt: Date
    }

    // MARK: - State

    private(set) var goal: String = ""
    private(set) var plan: [SubTaskEntry] = []
    private(set) var sharedData: [String: String] = [:]  // global KV store
    private(set) var screenshots: [(app: String, path: String, timestamp: Date)] = []
    private(set) var trajectory: [(agent: String, action: String, result: String, timestamp: Date)] = []
    private var createdAt = Date()

    // MARK: - Plan Management

    /// Initialize the blackboard with a goal and decomposed plan.
    func setPlan(goal: String, subtasks: [(id: String, description: String, targetApp: String?, toolHints: [String])]) {
        self.goal = goal
        self.createdAt = Date()
        self.plan = subtasks.map { st in
            SubTaskEntry(
                id: st.id,
                description: st.description,
                targetApp: st.targetApp,
                toolHints: st.toolHints,
                status: .pending,
                result: nil,
                sharedData: [:],
                startTime: Date(),
                endTime: nil
            )
        }
        self.sharedData = [:]
        self.screenshots = []
        self.trajectory = []
    }

    /// Get the next pending subtask (respects ordering).
    func nextPendingSubTask() -> SubTaskEntry? {
        plan.first { $0.status == .pending }
    }

    /// Mark a subtask as running.
    func markRunning(id: String) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .running
    }

    /// Complete a subtask with its result and any shared data it produced.
    func completeSubTask(id: String, result: String, sharedData: [String: String] = [:]) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .completed
        plan[idx].result = result
        plan[idx].endTime = Date()
        plan[idx].sharedData = sharedData

        // Merge subtask's shared data into global store
        for (key, value) in sharedData {
            self.sharedData[key] = value
        }
    }

    /// Fail a subtask with a reason.
    func failSubTask(id: String, reason: String) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .failed
        plan[idx].result = reason
        plan[idx].endTime = Date()
    }

    // MARK: - Shared Data

    /// Write a key-value pair to the global shared data store.
    func setSharedData(key: String, value: String) {
        sharedData[key] = value
    }

    /// Read a value from the global shared data store.
    func getSharedData(key: String) -> String? {
        sharedData[key]
    }

    // MARK: - Trajectory (action log)

    func recordAction(agent: String, action: String, result: String) {
        trajectory.append((agent: agent, action: action, result: result, timestamp: Date()))
        // Keep trajectory bounded
        if trajectory.count > 100 {
            trajectory = Array(trajectory.suffix(80))
        }
    }

    func addScreenshot(app: String, path: String) {
        screenshots.append((app: app, path: path, timestamp: Date()))
        if screenshots.count > 20 {
            screenshots = Array(screenshots.suffix(15))
        }
    }

    // MARK: - Context for LLM Injection

    /// Returns a prompt section summarizing completed subtasks and shared data,
    /// injected into the AppAgent's system prompt so it has full context.
    func contextForSubTask(id: String) -> String {
        var lines: [String] = []

        lines.append("## Task Context (Blackboard)")
        lines.append("Overall goal: \(goal)")

        // Completed subtask results
        let completed = plan.filter { $0.status == .completed }
        if !completed.isEmpty {
            lines.append("\nCompleted steps:")
            for st in completed {
                lines.append("- \(st.description): \(st.result ?? "done")")
            }
        }

        // Shared data from prior steps
        if !sharedData.isEmpty {
            lines.append("\nShared data from prior steps:")
            for (key, value) in sharedData {
                let preview = value.count > 500 ? String(value.prefix(500)) + "..." : value
                lines.append("- \(key): \(preview)")
            }
        }

        // Current subtask
        if let current = plan.first(where: { $0.id == id }) {
            lines.append("\nYour subtask: \(current.description)")
            if let app = current.targetApp {
                lines.append("Target app: \(app)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Status

    var isComplete: Bool {
        !plan.isEmpty && plan.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    var progress: Double {
        guard !plan.isEmpty else { return 0 }
        let done = plan.filter { $0.status == .completed || $0.status == .failed }.count
        return Double(done) / Double(plan.count)
    }

    func snapshot() -> PlanSnapshot {
        PlanSnapshot(goal: goal, subtasks: plan, createdAt: createdAt)
    }

    /// Reset the blackboard for a new task.
    func reset() {
        goal = ""
        plan = []
        sharedData = [:]
        screenshots = []
        trajectory = []
        createdAt = Date()
    }
}
