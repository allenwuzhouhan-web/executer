import Foundation

/// Self-adjusting confidence thresholds based on actual success rates.
enum ConfidenceCalibrator {

    /// Calibrate the confidence threshold for predictions.
    /// Returns the threshold above which predictions should be shown.
    static func calibratedThreshold() -> Double {
        let accuracy = PredictionEvaluator.shared.accuracy()

        // If accuracy is high (>70%), we can lower the threshold
        if accuracy > 0.7 { return 0.5 }
        // If accuracy is medium, use default
        if accuracy > 0.5 { return 0.7 }
        // If accuracy is low, raise the threshold
        return 0.85
    }

    /// Calibrate the suggestion confidence threshold.
    static func calibratedSuggestionThreshold() -> Double {
        let rate = SuggestionFeedback.acceptanceRate()

        if rate > 0.5 { return 0.5 }
        if rate > 0.3 { return 0.7 }
        return 0.85
    }
}
