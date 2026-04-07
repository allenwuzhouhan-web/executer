import Foundation

/// Implements confidence scoring per the Seven Principles.
///
/// Formula:
///   confidence = min(1.0, base × frequency × consistency × recency)
///
/// Principle 1: Nothing learned from a single observation. base = 0 if distinct_days < 3.
/// Principle 2: Recency matters, but not more than consistency. Heavy flywheel.
/// Principle 5: Decay is essential. Half-life = 14 days.
enum ConfidenceCalculator {

    /// Calculate confidence for a pattern given its observation history.
    ///
    /// - Parameters:
    ///   - occurrences: Total number of times this pattern was observed
    ///   - distinctDays: Number of distinct calendar days it was observed on
    ///   - observationDates: The actual dates of each observation (for recency calculation)
    ///   - expectedMax: Expected maximum occurrences for this pattern type (scales frequency_factor)
    ///   - expectedOccurrences: How many times we'd expect this pattern if it were consistent
    ///                          (e.g., if we're checking a daily routine over 14 days, expected = 14)
    /// - Returns: Confidence score 0.0–1.0
    static func calculate(
        occurrences: Int,
        distinctDays: Int,
        observationDates: [Date],
        expectedMax: Int = 50,
        expectedOccurrences: Int? = nil
    ) -> Double {
        // Principle 1: Nothing is learned from a single observation.
        // Require observations across >= 3 separate days before any base score.
        let baseScore: Double = distinctDays >= 3 ? 0.3 : 0.0
        guard baseScore > 0 else { return 0.0 }

        // Frequency factor: log-scaled so early observations matter more than later ones.
        // log2(occurrences) / log2(expectedMax) scales roughly 0 to 1.
        let frequencyFactor = min(1.0, log2(Double(max(occurrences, 1))) / log2(Double(max(expectedMax, 2))))

        // Consistency factor: how regular vs sporadic is this pattern?
        // actual / expected. If we expect a daily pattern over 14 days but only see it 7 times, consistency = 0.5.
        let expected = expectedOccurrences ?? max(distinctDays, 1)
        let consistencyFactor = min(1.0, Double(occurrences) / Double(max(expected, 1)))

        // Recency factor (Principle 2 + 5): exponential decay, half-life 14 days.
        // Average the decay-weighted contributions of each observation.
        let recencyFactor = Self.recencyFactor(dates: observationDates)

        let raw = baseScore * frequencyFactor * consistencyFactor * recencyFactor
        // Scale up: base 0.3 × 1.0 × 1.0 × 1.0 = 0.3 at minimum.
        // We want a well-established pattern to reach 0.7+, so multiply by ~3.3 and clamp.
        let scaled = raw * 3.33
        return min(1.0, scaled)
    }

    /// Compute the recency factor: mean of exponential-decayed weights for each observation date.
    /// Half-life = 14 days. λ = ln(2)/14 ≈ 0.0495.
    ///
    /// Principle 2: a pattern observed 50 times over 2 months should NOT be overwritten
    /// by 2 days of different behavior. The heavy flywheel effect comes from averaging
    /// across ALL observation dates, not just the most recent.
    static func recencyFactor(dates: [Date]) -> Double {
        guard !dates.isEmpty else { return 0.0 }

        let now = Date()
        let lambda = 0.0495  // ln(2)/14
        var totalWeight = 0.0

        for date in dates {
            let daysSince = max(0, now.timeIntervalSince(date) / 86400.0)
            totalWeight += exp(-lambda * daysSince)
        }

        return totalWeight / Double(dates.count)
    }

    /// Compute the decay factor for a single observation age.
    /// Used by DecayEngine for daily belief decay.
    static func decayFactor(daysSinceLastObserved: Double) -> Double {
        let lambda = 0.0495  // ln(2)/14 — 14-day half-life
        return exp(-lambda * daysSinceLastObserved)
    }

    /// Quick confidence check: does this pattern meet the minimum threshold to become a hypothesis?
    static func meetsHypothesisThreshold(occurrences: Int, distinctDays: Int) -> Bool {
        // Principle 1: need observations across >= 3 separate days
        return distinctDays >= 3 && occurrences >= 3
    }

    /// Interaction-weighted occurrence count.
    /// Active choices count fully, passive drift counts at 10% (Principle 4).
    static func weightedCount(weights: [Double]) -> Double {
        weights.reduce(0, +)
    }
}
