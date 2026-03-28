import Foundation

/// Tracks what the user focuses on per app, weighted by dwell time.
/// Builds up per-app attention profiles over time.
final class AttentionTracker {
    static let shared = AttentionTracker()

    /// In-memory cache of recent observations (today only).
    private var todayObservations: [SemanticObservation] = []
    private let lock = NSLock()

    private init() {}

    /// Record new observations from the attention extractors.
    func record(_ observations: [SemanticObservation]) {
        lock.lock()
        todayObservations.append(contentsOf: observations)
        // Keep only today's observations in memory
        let startOfDay = Calendar.current.startOfDay(for: Date())
        todayObservations.removeAll { $0.timestamp < startOfDay }
        lock.unlock()
    }

    /// Get all observations for today.
    func todaysObservations() -> [SemanticObservation] {
        lock.lock()
        defer { lock.unlock() }
        return todayObservations
    }

    /// Get observations for a specific app today.
    func observations(forApp appName: String) -> [SemanticObservation] {
        lock.lock()
        defer { lock.unlock() }
        return todayObservations.filter { $0.appName == appName }
    }

    /// Get the top topics the user has been working on today.
    func topTopicsToday(limit: Int = 10) -> [String] {
        lock.lock()
        let obs = todayObservations
        lock.unlock()

        var frequency: [String: Int] = [:]
        for o in obs {
            for topic in o.relatedTopics {
                frequency[topic, default: 0] += 1
            }
        }

        return frequency.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Clear all cached observations.
    func clear() {
        lock.lock()
        todayObservations.removeAll()
        lock.unlock()
    }
}
