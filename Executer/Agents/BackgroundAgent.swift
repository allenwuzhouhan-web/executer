import Foundation

/// A single background agent instance that monitors a condition.
struct BackgroundAgent: Identifiable, Codable {
    let id: UUID
    let goal: String
    let trigger: TriggerCondition
    var state: AgentState
    let maxLifetimeMinutes: Int
    let createdAt: Date
    var lastCheckAt: Date?

    /// Non-codable runtime task handle.
    var task: Task<Void, Never>?

    /// Parent agent ID for subagent chaining.
    var parentAgentId: UUID?

    /// Timestamped log entries for observability.
    var logs: [LogEntry] = []

    /// Final result when agent completes.
    var result: String?

    /// Estimated progress (0.0–1.0).
    var progress: Double = 0.0

    // MARK: - Codable (exclude `task`)

    enum CodingKeys: String, CodingKey {
        case id, goal, trigger, state, maxLifetimeMinutes, createdAt
        case lastCheckAt, parentAgentId, logs, result, progress
    }

    struct LogEntry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let message: String

        init(_ message: String) {
            self.id = UUID()
            self.timestamp = Date()
            self.message = message
        }
    }

    enum AgentState: String, Codable {
        case running, paused, completed, failed, expired
        /// Agents that were running when the app quit get this state on reload.
        case pendingRestart
    }

    enum TriggerCondition: Codable, Equatable {
        case poll(intervalSeconds: Int, check: String)   // Periodic LLM check
        case fileChange(path: String)                     // Watch file modification
        case webPageChange(url: String)                   // Periodic fetch + diff
        case oneShot(command: String)                      // Run once in background
    }

    mutating func appendLog(_ message: String) {
        let entry = LogEntry(message)
        logs.append(entry)
        // Keep last 50 entries to avoid unbounded growth
        if logs.count > 50 { logs.removeFirst(logs.count - 50) }
    }
}
