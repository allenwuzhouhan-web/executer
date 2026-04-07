import Foundation

/// Orchestrates prediction from multiple signals: temporal, sequential, contextual.
final class PredictionEngine {
    static let shared = PredictionEngine()

    private var recentPredictions: [Prediction] = []
    private var routines: [Routine] = []
    private let lock = NSLock()

    private init() {}

    /// Softcap for bounding prediction confidence from individual sources.
    /// Inspired by Flash Attention 3's softcapping: prevents any single signal
    /// (temporal, sequence, goal) from dominating the combined prediction set.
    private let predictionSoftcap = 0.9

    /// Generate predictions based on current state.
    /// Applies softcapping (Flash Attention 3-inspired) to confidence scores
    /// before combining, preventing any single source from dominating.
    func predict() -> [Prediction] {
        var predictions: [Prediction] = []

        // 1. Temporal predictions (time-of-day routines)
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        for routine in routines where routine.confidence > 0.5 {
            if routine.triggerType == .timeOfDay {
                let routineHour = Int(routine.triggerValue.prefix(2)) ?? -1
                if routineHour == hour, let app = routine.targetApp {
                    // Softcap the confidence to prevent temporal signals from dominating
                    let cappedConfidence = FlashAttentionUtils.softcap(routine.confidence, cap: predictionSoftcap)
                    predictions.append(Prediction(
                        action: routine.actionDescription,
                        app: app,
                        confidence: cappedConfidence,
                        reasoning: routine.description,
                        source: .temporal
                    ))
                }
            }
        }

        // 2. Sequence predictions (what comes next based on recent actions)
        let recentActions = LearningDatabase.shared.recentObservations(forApp: "", limit: 10)
        if !recentActions.isEmpty {
            let seqPredictions = SequencePredictor.shared.predict(given: recentActions)
            for (action, prob) in seqPredictions where prob > 0.3 {
                let parts = action.split(separator: ":").map(String.init)
                let app = parts.count > 1 ? parts[1] : ""
                // Softcap sequence prediction confidence
                let cappedProb = FlashAttentionUtils.softcap(prob, cap: predictionSoftcap)
                predictions.append(Prediction(
                    action: "Next: \(action)",
                    app: app.isEmpty ? nil : app,
                    confidence: cappedProb,
                    reasoning: "Based on action sequence pattern",
                    source: .sequence
                ))
            }
        }

        // 3. Goal-driven predictions
        if let session = SessionDetector.shared.currentSession(),
           let goal = GoalTracker.shared.relevantGoal(for: session) {
            if let deadline = goal.deadline {
                let hoursLeft = deadline.timeIntervalSince(now) / 3600
                if hoursLeft < 4 && hoursLeft > 0 {
                    let cappedConfidence = FlashAttentionUtils.softcap(0.8, cap: predictionSoftcap)
                    predictions.append(Prediction(
                        action: "Focus on \(goal.topic) — deadline approaching",
                        confidence: cappedConfidence,
                        reasoning: "Goal deadline in \(Int(hoursLeft)) hours",
                        source: .goal
                    ))
                }
            }
        }

        // Sort by confidence, deduplicate
        predictions.sort { $0.confidence > $1.confidence }

        lock.lock()
        recentPredictions = Array(predictions.prefix(5))
        lock.unlock()

        return predictions
    }

    /// Get the most confident prediction (for prompt injection).
    func topPrediction() -> Prediction? {
        lock.lock()
        defer { lock.unlock() }
        return recentPredictions.first(where: { $0.confidence > 0.7 })
    }

    /// Update routines from mined data.
    func updateRoutines(_ newRoutines: [Routine]) {
        lock.lock()
        routines = newRoutines
        lock.unlock()
    }

    /// Get detected routines.
    func getRoutines() -> [Routine] {
        lock.lock()
        defer { lock.unlock() }
        return routines
    }
}
