import Foundation
import Accelerate

/// Monitors topic drift by maintaining a running centroid embedding
/// of the current task's semantic content. Fires when new observations
/// deviate beyond a configurable cosine distance threshold.
///
/// Uses NLEmbedding via TextEmbedder for on-device sentence vectors,
/// and Accelerate for fast vector arithmetic on the AMX coprocessor.
final class TopicDriftMonitor: Sendable {

    /// Cosine distance threshold above which a drift event fires.
    /// 0.6 = substantial topic change (well-calibrated default).
    /// Range: 0.0 (fires on any change) to 2.0 (never fires).
    let driftThreshold: Double

    /// Minimum observations before drift detection activates.
    /// Avoids false positives when the centroid hasn't stabilized.
    let minimumObservationsForDrift: Int

    init(driftThreshold: Double = 0.6, minimumObservationsForDrift: Int = 3) {
        self.driftThreshold = driftThreshold
        self.minimumObservationsForDrift = minimumObservationsForDrift
    }

    // MARK: - Drift Measurement

    /// Measure the drift between a new observation's topic and the current task centroid.
    /// Returns nil if embedding is unavailable or centroid hasn't stabilized.
    ///
    /// - Parameters:
    ///   - text: The semantic text to measure (intent + topic terms).
    ///   - context: The current task context with running centroid.
    /// - Returns: Cosine distance (0.0 = identical, 2.0 = opposite), or nil.
    func measureDrift(text: String, context: TaskContext) -> Double? {
        guard context.observationCount >= minimumObservationsForDrift else { return nil }
        guard let centroid = context.topicCentroid else { return nil }
        guard let newVector = TextEmbedder.sentenceVector(text) else { return nil }
        guard centroid.count == newVector.count else { return nil }

        let similarity = TextEmbedder.cosineSimilarity(centroid, newVector)
        // Convert similarity [-1, 1] to distance [0, 2]
        return 1.0 - similarity
    }

    /// Check if the given text represents a topic drift relative to the current task.
    ///
    /// - Parameters:
    ///   - text: Semantic text from the new observation.
    ///   - context: Current task context.
    /// - Returns: DriftResult with distance and whether threshold was exceeded.
    func checkDrift(text: String, context: TaskContext) -> DriftResult {
        guard let distance = measureDrift(text: text, context: context) else {
            return DriftResult(distance: 0, isDrifting: false, thresholdUsed: driftThreshold)
        }
        return DriftResult(
            distance: distance,
            isDrifting: distance > driftThreshold,
            thresholdUsed: driftThreshold
        )
    }

    /// Compute a new embedding vector for a set of topic terms.
    /// Averages individual word embeddings for a lightweight topic vector.
    func embedTopics(_ terms: [String]) -> [Double]? {
        let combinedText = terms.joined(separator: " ")
        return TextEmbedder.sentenceVector(combinedText)
    }

    // MARK: - Types

    struct DriftResult: Sendable {
        let distance: Double       // Cosine distance (0 = same topic, 2 = opposite)
        let isDrifting: Bool       // Whether distance > threshold
        let thresholdUsed: Double  // The threshold that was applied
    }
}
