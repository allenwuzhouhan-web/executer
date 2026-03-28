import Foundation

/// Tracks prediction accuracy and feeds back to improve models.
final class PredictionEvaluator {
    static let shared = PredictionEvaluator()

    private var evaluationLog: [(prediction: Prediction, wasCorrect: Bool, timestamp: Date)] = []
    private let lock = NSLock()

    private init() {}

    /// Evaluate a prediction against what actually happened.
    func evaluate(prediction: Prediction, actualAction: UserAction) {
        let correct = prediction.predictedApp?.lowercased() == actualAction.appName.lowercased()

        lock.lock()
        evaluationLog.append((prediction, correct, Date()))
        // Keep last 1000 evaluations
        if evaluationLog.count > 1000 {
            evaluationLog.removeFirst(evaluationLog.count - 1000)
        }
        lock.unlock()
    }

    /// Overall accuracy of predictions.
    func accuracy() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard !evaluationLog.isEmpty else { return 0 }
        let correct = evaluationLog.filter(\.wasCorrect).count
        return Double(correct) / Double(evaluationLog.count)
    }

    /// Accuracy by source type.
    func accuracyBySource() -> [Prediction.PredictionSource: Double] {
        lock.lock()
        let log = evaluationLog
        lock.unlock()

        var result: [Prediction.PredictionSource: Double] = [:]
        let grouped = Dictionary(grouping: log, by: \.prediction.source)
        for (source, entries) in grouped {
            let correct = entries.filter(\.wasCorrect).count
            result[source] = Double(correct) / Double(entries.count)
        }
        return result
    }

    /// Summary for reporting.
    func summary() -> String {
        let acc = accuracy()
        let count = evaluationLog.count
        var lines = ["Prediction accuracy: \(String(format: "%.1f%%", acc * 100)) over \(count) predictions"]

        let bySource = accuracyBySource()
        for (source, accuracy) in bySource.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  \(source.rawValue): \(String(format: "%.1f%%", accuracy * 100))")
        }

        return lines.joined(separator: "\n")
    }
}
