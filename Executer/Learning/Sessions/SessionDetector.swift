import Foundation

/// Detects coherent work sessions across apps.
/// Uses time gaps + topic overlap (Jaccard similarity) to group observations.
final class SessionDetector {
    static let shared = SessionDetector()

    /// Active sessions.
    private(set) var activeSessions: [WorkSession] = []
    /// Completed sessions for today.
    private(set) var completedSessions: [WorkSession] = []
    private let lock = NSLock()

    /// Gap threshold: if no observation for this long, close the session.
    private let sessionGapThreshold: TimeInterval = 30 * 60  // 30 minutes
    /// Topic similarity threshold for linking observations to a session (Jaccard).
    private let topicSimilarityThreshold = 0.3
    /// Maximum time to keep a session active.
    private let maxSessionDuration: TimeInterval = 8 * 3600  // 8 hours

    private init() {}

    /// Ingest new observations and assign them to sessions.
    func ingest(_ observations: [SemanticObservation]) {
        lock.lock()
        defer { lock.unlock() }

        for observation in observations {
            assignToSession(observation)
        }

        closeStaleSessionsLocked()
    }

    /// Assign a single observation to the best-matching active session,
    /// or create a new session.
    private func assignToSession(_ observation: SemanticObservation) {
        let obsTopics = Set(observation.relatedTopics)

        // Find best matching active session by topic overlap
        var bestIdx: Int?
        var bestScore: Double = 0

        for (i, session) in activeSessions.enumerated() {
            let intersection = session.topics.intersection(obsTopics)
            let union = session.topics.union(obsTopics)
            guard !union.isEmpty else { continue }
            let jaccard = Double(intersection.count) / Double(union.count)

            if jaccard > bestScore && jaccard >= topicSimilarityThreshold {
                bestScore = jaccard
                bestIdx = i
            }
        }

        // Also check time gap — even with topic match, if gap is too large, start new session
        if let idx = bestIdx {
            let timeSinceLastObs = observation.timestamp.timeIntervalSince(activeSessions[idx].endTime)
            if timeSinceLastObs > sessionGapThreshold {
                bestIdx = nil  // Too much time has passed
            }
        }

        if let idx = bestIdx {
            activeSessions[idx].addObservation(observation)
        } else {
            // Create new session
            activeSessions.append(WorkSession(observation: observation))
        }
    }

    /// Close sessions that have been inactive too long.
    private func closeStaleSessionsLocked() {
        let now = Date()
        var toClose: [Int] = []

        for (i, session) in activeSessions.enumerated() {
            let gap = now.timeIntervalSince(session.endTime)
            let duration = session.duration

            if gap > sessionGapThreshold || duration > maxSessionDuration {
                toClose.append(i)
            }
        }

        // Close in reverse order to maintain indices
        for i in toClose.reversed() {
            var session = activeSessions.remove(at: i)
            session.isActive = false
            completedSessions.append(session)
        }
    }

    /// Get the currently active session (most recent).
    func currentSession() -> WorkSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessions.last
    }

    /// Get all sessions for today (active + completed).
    func todaysSessions() -> [WorkSession] {
        lock.lock()
        defer { lock.unlock() }
        return completedSessions + activeSessions
    }

    /// Clear all sessions (call at end of day or on reset).
    func clearAll() {
        lock.lock()
        activeSessions.removeAll()
        completedSessions.removeAll()
        lock.unlock()
    }
}
