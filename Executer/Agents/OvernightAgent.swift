import Foundation
import AppKit

/// The autonomous overnight agent orchestrator.
/// Discovers tasks, executes them headlessly, chains BackgroundAgents for 8+ hour sessions,
/// and generates a morning report.
///
/// Activation: "work overnight" command, automation rule (11 PM), or manual API call.
@MainActor
class OvernightAgent: ObservableObject {
    static let shared = OvernightAgent()

    // MARK: - State

    @Published var isActive = false
    @Published var currentSessionId: UUID?

    private var sessionStartTime: Date?
    private var sessionEndTime: Date?
    private var actionsThisHour: Int = 0
    private var consecutiveFailures: Int = 0
    private var agentChainsUsed: Int = 0
    private var lastDiscoveryTime: Date = .distantPast
    private var overnightTask: Task<Void, Never>?

    /// Safety limits
    private let maxActionsPerHour = 50
    private let maxConsecutiveFailures = 3
    private let discoveryInterval: TimeInterval = 1800  // 30 min

    private static var sessionURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("overnight_session.json")
    }

    // MARK: - Lifecycle

    /// Activate the overnight agent. Runs until `endTime` (default: 7 AM next day).
    func activate(until endTime: Date? = nil) {
        guard !isActive else {
            print("[OvernightAgent] Already active")
            return
        }

        let sessionEnd = endTime ?? nextMorning()
        currentSessionId = UUID()
        sessionStartTime = Date()
        sessionEndTime = sessionEnd
        isActive = true
        actionsThisHour = 0
        consecutiveFailures = 0
        agentChainsUsed = 0

        print("[OvernightAgent] Activated until \(sessionEnd)")
        saveSession()

        // Post state change
        NotificationCenter.default.post(name: .overnightAgentStateChanged, object: nil,
                                        userInfo: ["isActive": true])

        // Start the overnight loop in a background task
        overnightTask = Task.detached(priority: .utility) { [weak self] in
            await self?.overnightLoop()
        }
    }

    /// Deactivate the overnight agent.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        overnightTask?.cancel()
        overnightTask = nil

        // Generate and route the morning report
        Task {
            let report = generateMorningReport()
            await OutputRouter.route(report)
        }

        print("[OvernightAgent] Deactivated — \(OvernightTaskQueue.shared.completedTasks().count) tasks completed")
        NotificationCenter.default.post(name: .overnightAgentStateChanged, object: nil,
                                        userInfo: ["isActive": false])
    }

    // MARK: - Main Loop

    /// The core overnight loop. Discovers tasks, executes them, sleeps between iterations.
    func overnightLoop() async {
        print("[OvernightAgent] Loop started")

        while isActive && isWithinWindow() && !Task.isCancelled {
            // 1. Discovery pass (every 30 min)
            if Date().timeIntervalSince(lastDiscoveryTime) >= discoveryInterval {
                await discoverAndEnqueue()
                lastDiscoveryTime = Date()
            }

            // 2. Execute next task
            if let task = OvernightTaskQueue.shared.dequeueNext() {
                guard checkSafetyBudget() else {
                    print("[OvernightAgent] Safety budget exhausted — pausing")
                    try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min pause
                    actionsThisHour = 0
                    consecutiveFailures = 0
                    continue
                }

                await executeTask(task)
            } else {
                // No pending tasks — sleep longer
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 min idle
                continue
            }

            // 3. Sleep between tasks (CPU budget)
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s between tasks

            // 4. Hourly action counter reset
            if let start = sessionStartTime {
                let hoursSinceStart = Date().timeIntervalSince(start) / 3600
                let expectedResets = Int(hoursSinceStart)
                if expectedResets > agentChainsUsed {
                    actionsThisHour = 0
                    agentChainsUsed = expectedResets
                }
            }
        }

        // Session ended
        if isActive {
            await MainActor.run { deactivate() }
        }
    }

    // MARK: - Task Discovery

    private func discoverAndEnqueue() async {
        let discovered = await TaskDiscoveryEngine.shared.discoverTasks()
        if !discovered.isEmpty {
            OvernightTaskQueue.shared.enqueueAll(discovered)
            print("[OvernightAgent] Enqueued \(discovered.count) new tasks")
        }
    }

    // MARK: - Task Execution

    private func executeTask(_ task: OvernightTask) async {
        OvernightTaskQueue.shared.markExecuting(id: task.id)
        let startTime = Date()

        // Safety check: NeverTouchList
        if NeverTouchList.isForbidden(actionDescription: task.description) ||
           NeverTouchList.isForbidden(actionDescription: task.title) {
            OvernightTaskQueue.shared.markSkipped(id: task.id, reason: "Blocked by NeverTouchList")
            print("[OvernightAgent] Skipped (NeverTouchList): \(task.title)")
            return
        }

        // Execute via LLM + tools (headless — no InputBar)
        do {
            let systemPrompt = buildOvernightSystemPrompt(task: task)
            let result = try await executeLLMTask(task: task, systemPrompt: systemPrompt)

            let duration = Int(Date().timeIntervalSince(startTime))
            let taskResult = OvernightTask.TaskResult(
                summary: String(result.prefix(200)),
                confidence: 0.7,
                outputPath: nil,
                toolsUsed: [],
                durationSeconds: duration
            )

            OvernightTaskQueue.shared.markCompleted(id: task.id, result: taskResult)
            await OutputRouter.routeTaskResult(task)
            consecutiveFailures = 0
            actionsThisHour += 1
            print("[OvernightAgent] Completed: \(task.title) (\(duration)s)")

        } catch {
            consecutiveFailures += 1
            OvernightTaskQueue.shared.markFailed(id: task.id, reason: error.localizedDescription)
            print("[OvernightAgent] Failed: \(task.title) — \(error)")
        }
    }

    /// Execute a task by spawning a one-shot background agent.
    /// Uses BackgroundAgentManager's existing LLM + tool execution (fully headless).
    private func executeLLMTask(task: OvernightTask, systemPrompt: String) async throws -> String {
        // Use a one-shot background agent — it has the full LLM+tool loop built in
        let command = """
        \(systemPrompt)

        TASK: \(task.title)
        DESCRIPTION: \(task.description)
        ACTION PLAN: \(task.actionPlan)

        Execute this task now. Use the minimum number of tool calls needed.
        """

        guard let agent = BackgroundAgentManager.shared.startAgent(
            goal: command,
            trigger: .oneShot(command: command),
            maxLifetimeMinutes: max(task.estimatedMinutes, 5)
        ) else {
            throw NSError(domain: "OvernightAgent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start background agent"])
        }

        // Wait for the agent to complete
        let result = await BackgroundAgentManager.shared.waitForAgent(
            id: agent.id,
            timeoutSeconds: task.estimatedMinutes * 60
        )

        return result ?? "Task executed (no output captured)"
    }

    // MARK: - System Prompt

    private func buildOvernightSystemPrompt(task: OvernightTask) -> String {
        """
        You are an autonomous overnight agent executing a task while the user sleeps.

        RULES:
        - Execute the task efficiently with minimal tool calls
        - Do NOT send messages, emails, or communicate on behalf of the user
        - Do NOT delete, move, or modify important files unless explicitly required
        - Do NOT make submissions to any external service
        - If unsure about an action, skip it — better to do nothing than to do wrong
        - Keep outputs organized — save files to appropriate directories
        - Maximum 5 tool calls for this task

        TASK SOURCE: \(task.source.rawValue)
        PRIORITY: \(task.priority)
        """
    }

    // MARK: - Safety

    private func checkSafetyBudget() -> Bool {
        if actionsThisHour >= maxActionsPerHour { return false }
        if consecutiveFailures >= maxConsecutiveFailures { return false }
        return true
    }

    private func isWithinWindow() -> Bool {
        guard let endTime = sessionEndTime else { return false }
        return Date() < endTime
    }

    private func nextMorning() -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 7
        components.minute = 0
        components.second = 0
        // If it's before 7 AM, use today's 7 AM. Otherwise, tomorrow's.
        var target = calendar.date(from: components)!
        if target <= Date() {
            target = calendar.date(byAdding: .day, value: 1, to: target)!
        }
        return target
    }

    // MARK: - Morning Report

    func generateMorningReport() -> OvernightReport {
        let queue = OvernightTaskQueue.shared
        return OvernightReport(
            sessionId: currentSessionId ?? UUID(),
            startTime: sessionStartTime ?? Date(),
            endTime: Date(),
            tasksCompleted: queue.completedTasks(),
            tasksFailed: queue.failedTasks(),
            tasksSkipped: queue.allTasks().filter { $0.state == .skipped },
            tasksNeedingReview: queue.needsReviewTasks(),
            totalActionsExecuted: actionsThisHour,
            agentChainsUsed: agentChainsUsed,
            estimatedTimeSavedMinutes: queue.completedTasks().reduce(0) { $0 + $1.estimatedMinutes }
        )
    }

    // MARK: - Session Persistence

    func saveSession() {
        let session = OvernightSession(
            sessionId: currentSessionId ?? UUID(),
            startTime: sessionStartTime ?? Date(),
            endTime: sessionEndTime ?? Date(),
            isActive: isActive
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: Self.sessionURL, options: .atomic)
        }
    }

    func loadSession() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let session = try? JSONDecoder().decode(OvernightSession.self, from: data),
              session.isActive,
              session.endTime > Date() else { return }

        // Resume interrupted session
        print("[OvernightAgent] Resuming interrupted session")
        activate(until: session.endTime)
    }

    // MARK: - Status

    func statusDescription() -> String {
        var lines = ["Overnight Agent:"]
        lines.append("  Status: \(isActive ? "ACTIVE" : "inactive")")
        if let start = sessionStartTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            lines.append("  Started: \(formatter.string(from: start))")
        }
        if let end = sessionEndTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            lines.append("  Ends: \(formatter.string(from: end))")
        }
        lines.append("  Actions this hour: \(actionsThisHour)/\(maxActionsPerHour)")
        lines.append("  Queue: \(OvernightTaskQueue.shared.pendingTasks().count) pending, \(OvernightTaskQueue.shared.completedTasks().count) completed")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Session Model

struct OvernightSession: Codable {
    let sessionId: UUID
    let startTime: Date
    let endTime: Date
    let isActive: Bool
}
