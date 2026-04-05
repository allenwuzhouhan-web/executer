import Foundation

/// Learns per-user boundary detection thresholds from correction feedback.
///
/// When the user merges two tasks ("those were the same task") or splits one
/// ("that was actually two tasks"), the calibrator adjusts signal weights to
/// reduce future errors. Persists calibrated weights to UserDefaults.
///
/// Calibration is conservative: weights change slowly (±0.02 per correction)
/// to prevent oscillation. After 50+ corrections, the system has learned
/// the user's personal task-switching style.
actor BoundaryCalibrator {

    /// Key for persisting calibrated weights.
    private static let weightsKey = "com.executer.boundaryCalibrator.weights"
    private static let thresholdKey = "com.executer.boundaryCalibrator.threshold"
    private static let statsKey = "com.executer.boundaryCalibrator.stats"

    /// Learning rate for weight adjustments.
    private let learningRate: Double = 0.02

    /// Cached weights (loaded from UserDefaults on first access).
    private var cachedWeights: [BoundarySignal: Double]?
    private var cachedThreshold: Double?

    /// Calibration statistics.
    private var stats: CalibrationStats

    struct CalibrationStats: Codable {
        var totalBoundaries: Int = 0
        var mergeCorrections: Int = 0     // User said: "those were the same task"
        var splitCorrections: Int = 0     // User said: "that was two tasks"
        var averageTaskDuration: Double = 0
        var lastCalibrationDate: Date?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: BoundaryCalibrator.statsKey),
           let decoded = try? JSONDecoder().decode(CalibrationStats.self, from: data) {
            stats = decoded
        } else {
            stats = CalibrationStats()
        }
    }

    // MARK: - Weight Access

    /// Get the current calibrated weights, or empty if using defaults.
    func currentWeights() -> [BoundarySignal: Double] {
        if let cached = cachedWeights { return cached }

        guard let data = UserDefaults.standard.data(forKey: BoundaryCalibrator.weightsKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }

        var weights: [BoundarySignal: Double] = [:]
        for (key, value) in decoded {
            if let signal = BoundarySignal(rawValue: key) {
                weights[signal] = value
            }
        }
        cachedWeights = weights
        return weights
    }

    /// Get the current calibrated threshold, or 0 if using default.
    func currentThreshold() -> Double {
        if let cached = cachedThreshold { return cached }

        let value = UserDefaults.standard.double(forKey: BoundaryCalibrator.thresholdKey)
        cachedThreshold = value
        return value
    }

    // MARK: - Recording

    /// Record a boundary that was emitted (for tracking stats).
    func recordBoundary(_ boundary: TaskBoundary, previousTaskDuration: TimeInterval) {
        stats.totalBoundaries += 1

        // Update running average of task duration
        let n = Double(stats.totalBoundaries)
        stats.averageTaskDuration = stats.averageTaskDuration * ((n - 1) / n) + previousTaskDuration / n

        persistStats()
    }

    // MARK: - Corrections

    /// User correction: "those were the same task" — the boundary was a false positive.
    /// Decrease the weights of the signals that contributed to the boundary.
    func correctMerge(boundary: TaskBoundary) {
        stats.mergeCorrections += 1
        stats.lastCalibrationDate = Date()

        var weights = currentWeights()
        // Use defaults if no calibrated weights yet
        if weights.isEmpty {
            weights = defaultWeights()
        }

        // Decrease weights of signals that contributed to this false positive
        for contribution in boundary.signals where contribution.weight > 0.1 {
            let current = weights[contribution.signal, default: defaultWeight(for: contribution.signal)]
            weights[contribution.signal] = max(0.05, current - learningRate)
        }

        // Also slightly increase the threshold (be more conservative)
        let threshold = currentThreshold() > 0 ? currentThreshold() : 0.55
        cachedThreshold = min(1.0, threshold + learningRate / 2)

        cachedWeights = weights
        persistWeights(weights)
        persistThreshold()
        persistStats()

        print("[Calibrator] Merge correction applied — weights adjusted down for \(boundary.signals.count) signals")
    }

    /// User correction: "that was actually two tasks" — a boundary was missed.
    /// Increase the weights of signals that should have triggered.
    func correctSplit(missedSignals: [BoundarySignal]) {
        stats.splitCorrections += 1
        stats.lastCalibrationDate = Date()

        var weights = currentWeights()
        if weights.isEmpty {
            weights = defaultWeights()
        }

        // Increase weights of signals that should have caught this
        for signal in missedSignals {
            let current = weights[signal, default: defaultWeight(for: signal)]
            weights[signal] = min(0.8, current + learningRate)
        }

        // Also slightly decrease the threshold (be more aggressive)
        let threshold = currentThreshold() > 0 ? currentThreshold() : 0.55
        cachedThreshold = max(0.2, threshold - learningRate / 2)

        cachedWeights = weights
        persistWeights(weights)
        persistThreshold()
        persistStats()

        print("[Calibrator] Split correction applied — weights adjusted up for \(missedSignals.count) signals")
    }

    /// Reset calibration to defaults.
    func reset() {
        cachedWeights = nil
        cachedThreshold = nil
        stats = CalibrationStats()
        UserDefaults.standard.removeObject(forKey: BoundaryCalibrator.weightsKey)
        UserDefaults.standard.removeObject(forKey: BoundaryCalibrator.thresholdKey)
        UserDefaults.standard.removeObject(forKey: BoundaryCalibrator.statsKey)
        print("[Calibrator] Reset to defaults")
    }

    // MARK: - Defaults

    private func defaultWeights() -> [BoundarySignal: Double] {
        [
            .appSwitchPattern: 0.25,
            .documentChange: 0.30,
            .topicDrift: 0.25,
            .temporalGap: 0.35,
            .systemEvent: 0.40,
        ]
    }

    private func defaultWeight(for signal: BoundarySignal) -> Double {
        defaultWeights()[signal] ?? 0.25
    }

    // MARK: - Persistence

    private func persistWeights(_ weights: [BoundarySignal: Double]) {
        let encoded = Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: BoundaryCalibrator.weightsKey)
        }
    }

    private func persistThreshold() {
        if let threshold = cachedThreshold {
            UserDefaults.standard.set(threshold, forKey: BoundaryCalibrator.thresholdKey)
        }
    }

    private func persistStats() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: BoundaryCalibrator.statsKey)
        }
    }

    // MARK: - Status

    /// Get calibration status for display.
    func statusDescription() -> String {
        var lines: [String] = ["Boundary Calibrator:"]
        lines.append("  Total boundaries: \(stats.totalBoundaries)")
        lines.append("  Merge corrections: \(stats.mergeCorrections)")
        lines.append("  Split corrections: \(stats.splitCorrections)")
        lines.append("  Avg task duration: \(Int(stats.averageTaskDuration))s")

        let weights = currentWeights()
        if !weights.isEmpty {
            lines.append("  Calibrated weights: \(weights.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: ", "))")
        } else {
            lines.append("  Using default weights")
        }

        if let date = stats.lastCalibrationDate {
            let formatter = RelativeDateTimeFormatter()
            lines.append("  Last calibration: \(formatter.localizedString(for: date, relativeTo: Date()))")
        }

        return lines.joined(separator: "\n")
    }
}
