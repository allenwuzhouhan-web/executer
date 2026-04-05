import Foundation

/// Manages persistent agent sessions on disk.
/// Each session is stored as an individual JSON file in the agent_sessions directory.
/// Thread-safe via a serial dispatch queue for all disk I/O.
@MainActor
class AgentSessionStore {
    static let shared = AgentSessionStore()

    /// Maximum number of sessions retained on disk.
    private static let maxSessions = 20

    /// In-memory cache of the current (most recent) session.
    private(set) var activeSession: AgentSession?

    /// Recently completed sessions (loaded on init, kept in memory for quick access).
    private(set) var recentSessions: [AgentSession] = []

    private static var sessionsDirectory: URL {
        let appSupport = URL.applicationSupportDirectory
        return appSupport.appendingPathComponent("Executer/agent_sessions")
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        ensureDirectory()
        loadRecentSessions()
    }

    // MARK: - Session Lifecycle

    /// Start a new session. Returns the session ID for checkpointing.
    @discardableResult
    func startSession(command: String, agentId: String, messages: [ChatMessage]) -> AgentSession {
        let session = AgentSession(
            command: command,
            agentId: agentId,
            messages: messages,
            state: .running
        )
        activeSession = session
        saveToDisk(session)
        return session
    }

    /// Checkpoint: update messages and iteration count for the active session.
    /// Called after each agent loop iteration so progress survives a crash.
    func checkpoint(messages: [ChatMessage], iteration: Int) {
        guard var session = activeSession else { return }
        session.messages = messages
        session.lastIteration = iteration
        session.updatedAt = Date()
        activeSession = session
        saveToDisk(session)
    }

    /// Mark the active session as completed with a result and optional trace.
    func complete(result: String, richResultRaw: String? = nil, messages: [ChatMessage], trace: AgentTrace?) {
        guard var session = activeSession else { return }
        session.state = .completed
        session.result = result
        session.richResultRaw = richResultRaw
        session.messages = messages
        session.trace = trace?.snapshot()
        session.updatedAt = Date()
        activeSession = session
        saveToDisk(session)
        recentSessions.insert(session, at: 0)
        pruneOldSessions()
    }

    /// Mark the active session as failed with an error message and optional trace.
    func fail(error: String, trace: AgentTrace?) {
        guard var session = activeSession else { return }
        session.state = .failed
        session.result = error
        session.trace = trace?.snapshot()
        session.updatedAt = Date()
        activeSession = session
        saveToDisk(session)
        recentSessions.insert(session, at: 0)
    }

    /// Mark the active session as cancelled.
    func cancel() {
        guard var session = activeSession else { return }
        session.state = .cancelled
        session.updatedAt = Date()
        activeSession = session
        saveToDisk(session)
    }

    /// Clear the active session reference (does NOT delete from disk).
    func clearActive() {
        activeSession = nil
    }

    // MARK: - App Lifecycle

    /// Called on app termination. Marks any running session as interrupted.
    func markRunningAsInterrupted() {
        guard var session = activeSession, session.state == .running else { return }
        session.state = .interrupted
        session.updatedAt = Date()
        activeSession = session
        saveToDisk(session)
        print("[AgentSessionStore] Marked session \(session.id.uuidString.prefix(8)) as interrupted")
    }

    /// Find the most recent interrupted session (if any) for resume on launch.
    func findInterruptedSession() -> AgentSession? {
        // Check the active session first
        if let active = activeSession, active.state == .interrupted {
            return active
        }
        // Then check recent sessions
        return recentSessions.first { $0.state == .interrupted }
    }

    /// Resume an interrupted session: set state back to running and make it active.
    func resumeSession(_ session: AgentSession) -> AgentSession {
        var resumed = session
        resumed.state = .running
        resumed.updatedAt = Date()
        activeSession = resumed
        saveToDisk(resumed)
        return resumed
    }

    /// Dismiss an interrupted session without resuming (mark as cancelled).
    func dismissInterrupted(_ session: AgentSession) {
        var dismissed = session
        dismissed.state = .cancelled
        dismissed.updatedAt = Date()
        saveToDisk(dismissed)
        if activeSession?.id == session.id {
            activeSession = nil
        }
        if let idx = recentSessions.firstIndex(where: { $0.id == session.id }) {
            recentSessions[idx] = dismissed
        }
    }

    /// Get conversation messages from the last completed/interrupted session for follow-up.
    func lastSessionMessages() -> [ChatMessage]? {
        let candidate = activeSession ?? recentSessions.first
        guard let session = candidate else { return nil }
        guard session.state == .completed || session.state == .interrupted else { return nil }
        // Only return if session is recent (within 10 minutes)
        guard Date().timeIntervalSince(session.updatedAt) < 600 else { return nil }
        return session.messages
    }

    // MARK: - Disk I/O

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for sessionId: UUID) -> URL {
        Self.sessionsDirectory.appendingPathComponent("\(sessionId.uuidString).json")
    }

    private func saveToDisk(_ session: AgentSession) {
        do {
            let data = try encoder.encode(session)
            try data.write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            print("[AgentSessionStore] Failed to save session \(session.id.uuidString.prefix(8)): \(error)")
        }
    }

    private func loadFromDisk(_ url: URL) -> AgentSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentSession.self, from: data)
    }

    private func loadRecentSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }

        // Load all sessions, sort by updatedAt descending
        var sessions: [AgentSession] = jsonFiles.compactMap { loadFromDisk($0) }
        sessions.sort { $0.updatedAt > $1.updatedAt }

        // Mark any that were "running" as interrupted (app crashed without clean shutdown)
        for i in sessions.indices where sessions[i].state == .running {
            sessions[i].state = .interrupted
            sessions[i].updatedAt = Date()
            saveToDisk(sessions[i])
        }

        recentSessions = sessions
        // Set the most recent non-terminal session as active
        if let interrupted = sessions.first(where: { $0.state == .interrupted }) {
            activeSession = interrupted
        }

        print("[AgentSessionStore] Loaded \(sessions.count) sessions (\(sessions.filter { $0.state == .interrupted }.count) interrupted)")
    }

    private func pruneOldSessions() {
        guard recentSessions.count > Self.maxSessions else { return }
        let toRemove = recentSessions.suffix(from: Self.maxSessions)
        for session in toRemove {
            try? FileManager.default.removeItem(at: fileURL(for: session.id))
        }
        recentSessions = Array(recentSessions.prefix(Self.maxSessions))
    }
}
