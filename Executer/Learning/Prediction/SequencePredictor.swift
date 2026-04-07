import Foundation
import Accelerate

/// N-gram model over action sequences for next-action prediction.
/// Stores transition probabilities: given last N actions, what comes next?
///
/// Flash Attention-inspired: applies causal masking to prevent cross-session
/// action leakage, ensuring predictions only depend on causally valid past actions.
final class SequencePredictor {
    static let shared = SequencePredictor()

    /// Transition counts: contextHash → [nextAction → count]
    private var transitions: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private let contextLength = 3 // Use last 3 actions as context

    /// Session boundary markers — indices where new sessions begin.
    /// Prevents N-gram transitions from crossing session boundaries (causal masking).
    private var sessionBoundaries: Set<Int> = []
    private var totalActionsProcessed: Int = 0

    private init() {}

    // MARK: - Session Boundary Management (Causal Masking)

    /// Mark the start of a new session. Any N-gram window spanning this boundary
    /// will be masked out, preventing cross-session action leakage.
    func markSessionBoundary() {
        lock.lock()
        sessionBoundaries.insert(totalActionsProcessed)
        lock.unlock()
    }

    /// Update the model with a sequence of actions, respecting causal session boundaries.
    func train(on actions: [UserAction]) {
        guard actions.count > contextLength else { return }

        lock.lock()
        defer { lock.unlock() }

        let baseIndex = totalActionsProcessed

        for i in contextLength..<actions.count {
            let globalPos = baseIndex + i

            // Causal masking: check if the N-gram window crosses a session boundary
            let windowStart = baseIndex + (i - contextLength)
            let crossesBoundary = sessionBoundaries.contains(where: { boundary in
                boundary > windowStart && boundary <= globalPos
            })

            if crossesBoundary {
                // Skip this transition — it would leak cross-session information
                continue
            }

            let context = actions[(i - contextLength)..<i].map(\.signature).joined(separator: "|")
            let next = actions[i].signature
            transitions[context, default: [:]][next, default: 0] += 1
        }

        totalActionsProcessed += actions.count

        // Prune old session boundaries (keep last 1000)
        if sessionBoundaries.count > 1000 {
            let sorted = sessionBoundaries.sorted()
            sessionBoundaries = Set(sorted.suffix(1000))
        }
    }

    /// Predict the next action given recent actions.
    /// Only uses causally valid transitions (no cross-session leakage).
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

    /// Predict with causal mask validation — verifies the context doesn't span a session break.
    func predictCausal(given recentActions: [UserAction], topK: Int = 3) -> [(action: String, probability: Double)] {
        guard recentActions.count >= contextLength else { return [] }

        // Check if the most recent context window is within a single session
        let windowStart = totalActionsProcessed - contextLength
        let crossesBoundary = sessionBoundaries.contains(where: { boundary in
            boundary > windowStart && boundary <= totalActionsProcessed
        })

        if crossesBoundary {
            // Context spans a session boundary — predictions would be unreliable
            return []
        }

        return predict(given: recentActions, topK: topK)
    }

    /// Clear the model.
    func reset() {
        lock.lock()
        transitions.removeAll()
        sessionBoundaries.removeAll()
        totalActionsProcessed = 0
        lock.unlock()
    }
}
