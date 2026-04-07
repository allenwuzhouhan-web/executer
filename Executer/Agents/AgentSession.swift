import Foundation

// MARK: - Agent Session

/// A persistable snapshot of a foreground agent execution.
/// Captures everything needed to resume an interrupted agent or replay its results.
struct AgentSession: Codable, Identifiable {
    let id: UUID
    let command: String
    let agentId: String
    var messages: [ChatMessage]
    var state: SessionState
    var result: String?
    var richResultRaw: String?
    var trace: PersistedTrace?
    let createdAt: Date
    var updatedAt: Date
    /// The iteration the agent was on when last checkpointed.
    var lastIteration: Int

    enum SessionState: String, Codable {
        case running
        case completed
        case failed
        case interrupted   // was running when the app quit
        case cancelled
    }

    init(
        command: String,
        agentId: String,
        messages: [ChatMessage] = [],
        state: SessionState = .running,
        result: String? = nil
    ) {
        self.id = UUID()
        self.command = command
        self.agentId = agentId
        self.messages = messages
        self.state = state
        self.result = result
        self.richResultRaw = nil
        self.trace = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastIteration = 0
    }
}

// MARK: - Persisted Trace

/// Codable snapshot of an AgentTrace, suitable for disk storage.
/// Created via `AgentTrace.snapshot()`.
struct PersistedTrace: Codable {
    let id: UUID
    let goal: String
    let startTime: Date
    var endTime: Date?
    var planOutput: String?
    var outcome: PersistedOutcome?
    var entries: [PersistedTraceEntry]

    enum PersistedOutcome: String, Codable {
        case success
        case failure
        case cancelled
    }

    /// Reconstruct a live AgentTrace from persisted data.
    func restore() -> AgentTrace {
        let trace = AgentTrace(goal: goal, id: id, startTime: startTime)
        trace.endTime = endTime
        trace.planOutput = planOutput
        switch outcome {
        case .success:  trace.finalOutcome = .success
        case .failure:  trace.finalOutcome = .failure("")
        case .cancelled: trace.finalOutcome = .cancelled
        case .none: break
        }
        for entry in entries {
            trace.append(entry.restore())
        }
        return trace
    }
}

// MARK: - Persisted Trace Entry

/// Codable version of TraceEntry.
struct PersistedTraceEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let durationMs: Double?
    let kind: PersistedTraceEntryKind

    func restore() -> TraceEntry {
        TraceEntry(kind: kind.restore(), durationMs: durationMs, id: id, timestamp: timestamp)
    }
}

/// Codable version of TraceEntryKind.
enum PersistedTraceEntryKind: Codable {
    case llmCall(messageCount: Int, responseLength: Int, hasToolCalls: Bool, reasoning: String?)
    case toolCall(name: String, arguments: String, result: String, durationMs: Double, success: Bool)
    case planning(output: String)
    case subAgentDecomposition(taskCount: Int)
    case webScrape(url: String, contentPreview: String)
    case error(source: String, message: String)
    case contextPrune(beforeTokens: Int, afterTokens: Int)
    case retry(toolName: String, attempt: Int, reason: String)
    case selfEvaluation(passed: Bool, feedback: String)
    case subAgentComplete(id: String, app: String?, durationMs: Double, success: Bool)
    case hostAgentRouting(subtaskCount: Int, apps: [String])

    func restore() -> TraceEntryKind {
        switch self {
        case .llmCall(let mc, let rl, let ht, let r):
            return .llmCall(messageCount: mc, responseLength: rl, hasToolCalls: ht, reasoning: r)
        case .toolCall(let n, let a, let r, let d, let s):
            return .toolCall(name: n, arguments: a, result: r, durationMs: d, success: s)
        case .planning(let o):
            return .planning(output: o)
        case .subAgentDecomposition(let c):
            return .subAgentDecomposition(taskCount: c)
        case .webScrape(let u, let c):
            return .webScrape(url: u, contentPreview: c)
        case .error(let s, let m):
            return .error(source: s, message: m)
        case .contextPrune(let b, let a):
            return .contextPrune(beforeTokens: b, afterTokens: a)
        case .retry(let t, let a, let r):
            return .retry(toolName: t, attempt: a, reason: r)
        case .selfEvaluation(let p, let f):
            return .selfEvaluation(passed: p, feedback: f)
        case .subAgentComplete(let id, let app, let d, let s):
            return .subAgentComplete(id: id, app: app, durationMs: d, success: s)
        case .hostAgentRouting(let c, let apps):
            return .hostAgentRouting(subtaskCount: c, apps: apps)
        }
    }
}
