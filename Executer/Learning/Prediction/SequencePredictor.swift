import Foundation
import Accelerate

/// N-gram model over action sequences for next-action prediction.
/// Stores transition probabilities: given last N actions, what comes next?
final class SequencePredictor {
    static let shared = SequencePredictor()

    /// Transition counts: contextHash → [nextAction → count]
    private var transitions: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private let contextLength = 3 // Use last 3 actions as context

    private init() {}

    /// Update the model with a sequence of actions.
    func train(on actions: [UserAction]) {
        guard actions.count > contextLength else { return }

        lock.lock()
        defer { lock.unlock() }

        for i in contextLength..<actions.count {
            let context = actions[(i - contextLength)..<i].map(\.signature).joined(separator: "|")
            let next = actions[i].signature
            transitions[context, default: [:]][next, default: 0] += 1
        }
    }

    /// Predict the next action given recent actions.
    func predict(given recentActions: [UserAction], topK: Int = 3) -> [(action: String, probability: Double)] {
        guard recentActions.count >= contextLength else { return [] }

        lock.lock()
        defer { lock.unlock() }

        let context = recentActions.suffix(contextLength).map(\.signature).joined(separator: "|")
        guard let nextActions = transitions[context], !nextActions.isEmpty else { return [] }

        let total = Double(nextActions.values.reduce(0, +))

        return nextActions
            .map { (action: $0.key, probability: Double($0.value) / total) }
            .sorted { $0.probability > $1.probability }
            .prefix(topK)
            .map { ($0.action, $0.probability) }
    }

    /// Clear the model.
    func reset() {
        lock.lock()
        transitions.removeAll()
        lock.unlock()
    }
}
