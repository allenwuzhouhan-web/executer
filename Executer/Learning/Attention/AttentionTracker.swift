import Foundation

/// Tracks what the user focuses on per app, weighted by dwell time.
/// Builds up per-app attention profiles over time.
///
/// Flash Attention-inspired: uses sliding window with exponential decay
/// for immediate context, keeping only recent N minutes at full weight.
final class AttentionTracker {
    static let shared = AttentionTracker()

    /// In-memory cache of recent observations (today only).
    private var todayObservations: [SemanticObservation] = []
    private let lock = NSLock()

    // MARK: - Sliding Window Configuration (Flash Attention-inspired)

    /// Window size in minutes for immediate context (full attention weight).
    private let immediateWindowMinutes: TimeInterval = 30

    /// Extended window in minutes (exponentially decayed attention).
    private let extendedWindowMinutes: TimeInterval = 120

    /// Decay factor per minute outside the immediate window.
    /// 0.95^30 ~ 0.21, so observations 30 min past the window have ~21% weight.
    private let decayPerMinute: Double = 0.95

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

    // MARK: - Sliding Window Observations (Flash Attention-inspired)

    /// Get observations within the sliding window, weighted by recency.
    /// Only recent observations get full weight; older ones decay exponentially.
    /// This is analogous to Flash Attention's sliding window attention where
    /// position i only attends to keys in [i - windowSize, i].
    func windowedObservations(windowMinutes: TimeInterval? = nil) -> [(observation: SemanticObservation, weight: Double)] {
        let window = windowMinutes ?? immediateWindowMinutes
        let now = Date()

        lock.lock()
        let obs = todayObservations
        lock.unlock()

        return obs.compactMap { observation in
            let ageMinutes = now.timeIntervalSince(observation.timestamp) / 60.0

            if ageMinutes <= window {
                // Within immediate window — full weight
                return (observation, 1.0)
            } else if ageMinutes <= extendedWindowMinutes {
                // Extended window — exponential decay
                let minutesPastWindow = ageMinutes - window
                let weight = pow(decayPerMinute, minutesPastWindow)
                return (observation, weight)
            } else {
                // Outside extended window — zero weight (masked out)
                return nil
            }
        }
    }

    /// Get the top topics using sliding window attention weighting.
    /// Topics from recent observations are weighted more heavily.
    func topTopicsWindowed(limit: Int = 10) -> [(topic: String, score: Double)] {
        let weighted = windowedObservations()

        var scores: [String: Double] = [:]
        for (obs, weight) in weighted {
            for topic in obs.relatedTopics {
                scores[topic, default: 0] += weight
            }
        }

        return scores.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
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

    // MARK: - Windowed App Focus

    /// Get app focus scores within the sliding window.
    /// Returns apps sorted by weighted observation count.
    func appFocusWindowed() -> [(app: String, score: Double)] {
        let weighted = windowedObservations()

        var scores: [String: Double] = [:]
        for (obs, weight) in weighted {
            scores[obs.appName, default: 0] += weight
        }

        return scores.sorted { $0.value > $1.value }.map { (app: $0.key, score: $0.value) }
    }

    /// Clear all cached observations.
    func clear() {
        lock.lock()
        todayObservations.removeAll()
        lock.unlock()
    }
}
