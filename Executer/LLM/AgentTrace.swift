import Foundation

// MARK: - Trace Entry Kind

/// Categorizes each event captured during agent execution.
enum TraceEntryKind {
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
}

// MARK: - Trace Entry

/// A single event in the agent execution timeline.
struct TraceEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: TraceEntryKind
    let durationMs: Double?

    init(kind: TraceEntryKind, durationMs: Double? = nil, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.durationMs = durationMs
    }

    /// One-line summary for timeline display.
    var summary: String {
        switch kind {
        case .llmCall(let msgCount, let respLen, let hasTools, _):
            return "LLM call (\(msgCount) msgs → \(respLen) chars\(hasTools ? ", tool calls" : ""))"
        case .toolCall(let name, _, _, let ms, let success):
            return "\(success ? "OK" : "FAIL") \(name) (\(Int(ms))ms)"
        case .planning:
            return "Planning phase"
        case .subAgentDecomposition(let count):
            return "Decomposed into \(count) sub-agents"
        case .webScrape(let url, _):
            return "Web scrape: \(url)"
        case .error(let source, let message):
            return "Error [\(source)]: \(message)"
        case .contextPrune(let before, let after):
            return "Context pruned: ~\(before) → ~\(after) tokens"
        case .retry(let name, let attempt, _):
            return "Retry #\(attempt) for \(name)"
        case .selfEvaluation(let passed, _):
            return "Self-eval: \(passed ? "passed" : "failed")"
        case .subAgentComplete(let id, let app, let ms, let success):
            return "\(success ? "OK" : "FAIL") AppAgent[\(app ?? id)] (\(Int(ms))ms)"
        case .hostAgentRouting(let count, let apps):
            return "HostAgent routing → \(count) subtasks (\(apps.joined(separator: ", ")))"
        }
    }

    /// Color identifier for timeline dots.
    var colorName: String {
        switch kind {
        case .llmCall: return "purple"
        case .toolCall(_, _, _, _, let success): return success ? "blue" : "red"
        case .planning: return "teal"
        case .subAgentDecomposition: return "teal"
        case .webScrape: return "orange"
        case .error: return "red"
        case .contextPrune: return "gray"
        case .retry: return "yellow"
        case .selfEvaluation(let passed, _): return passed ? "green" : "red"
        case .subAgentComplete(_, _, _, let success): return success ? "green" : "red"
        case .hostAgentRouting: return "teal"
        }
    }
}

// MARK: - Agent Trace

/// Complete execution trace for one agent task.
/// In-memory only — never persisted to disk (traces may contain sensitive data).
final class AgentTrace {

    enum Outcome {
        case success
        case failure(String)
        case cancelled
    }

    let id: UUID
    let goal: String
    let startTime: Date
    var endTime: Date?
    var planOutput: String?
    var finalOutcome: Outcome?

    private let lock = NSLock()
    private var _entries: [TraceEntry] = []

    var entries: [TraceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    init(goal: String, id: UUID = UUID(), startTime: Date = Date()) {
        self.id = id
        self.goal = goal
        self.startTime = startTime
    }

    /// Thread-safe append — called from detached tasks and TaskGroups.
    func append(_ entry: TraceEntry) {
        lock.lock()
        defer { lock.unlock() }
        _entries.append(entry)
    }

    // MARK: Computed Helpers

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    var toolCallCount: Int {
        entries.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }.count
    }

    var failedToolCalls: [TraceEntry] {
        entries.filter {
            if case .toolCall(_, _, _, _, let success) = $0.kind { return !success }
            return false
        }
    }

    var errorEntries: [TraceEntry] {
        entries.filter {
            if case .error = $0.kind { return true }
            return false
        }
    }

    var webScrapes: [TraceEntry] {
        entries.filter {
            if case .webScrape = $0.kind { return true }
            return false
        }
    }

    var llmCallCount: Int {
        entries.filter {
            if case .llmCall = $0.kind { return true }
            return false
        }.count
    }

    var formattedDuration: String {
        let d = duration
        if d < 1 { return "<1s" }
        if d < 60 { return String(format: "%.1fs", d) }
        return String(format: "%.0fm %.0fs", (d / 60).rounded(.down), d.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Persistence

    /// Create a Codable snapshot of this trace for disk storage.
    func snapshot() -> PersistedTrace {
        let persistedOutcome: PersistedTrace.PersistedOutcome?
        switch finalOutcome {
        case .success: persistedOutcome = .success
        case .failure: persistedOutcome = .failure
        case .cancelled: persistedOutcome = .cancelled
        case .none: persistedOutcome = nil
        }

        let persistedEntries: [PersistedTraceEntry] = entries.map { entry in
            let kind: PersistedTraceEntryKind
            switch entry.kind {
            case .llmCall(let mc, let rl, let ht, let r):
                kind = .llmCall(messageCount: mc, responseLength: rl, hasToolCalls: ht, reasoning: r)
            case .toolCall(let n, let a, let r, let d, let s):
                kind = .toolCall(name: n, arguments: a, result: r, durationMs: d, success: s)
            case .planning(let o):
                kind = .planning(output: o)
            case .subAgentDecomposition(let c):
                kind = .subAgentDecomposition(taskCount: c)
            case .webScrape(let u, let c):
                kind = .webScrape(url: u, contentPreview: c)
            case .error(let s, let m):
                kind = .error(source: s, message: m)
            case .contextPrune(let b, let a):
                kind = .contextPrune(beforeTokens: b, afterTokens: a)
            case .retry(let t, let a, let r):
                kind = .retry(toolName: t, attempt: a, reason: r)
            case .selfEvaluation(let p, let f):
                kind = .selfEvaluation(passed: p, feedback: f)
            case .subAgentComplete(let id, let app, let d, let s):
                kind = .subAgentComplete(id: id, app: app, durationMs: d, success: s)
            case .hostAgentRouting(let c, let apps):
                kind = .hostAgentRouting(subtaskCount: c, apps: apps)
            }
            return PersistedTraceEntry(id: entry.id, timestamp: entry.timestamp, durationMs: entry.durationMs, kind: kind)
        }

        return PersistedTrace(
            id: id, goal: goal, startTime: startTime,
            endTime: endTime, planOutput: planOutput,
            outcome: persistedOutcome, entries: persistedEntries
        )
    }
}
