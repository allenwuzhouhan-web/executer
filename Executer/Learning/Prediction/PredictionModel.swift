import Foundation

/// A prediction of the user's next action or behavior.
struct Prediction: Codable, Identifiable {
    let id: UUID
    let predictedAction: String     // "Open Slack" or "Switch to Keynote"
    let predictedApp: String?       // Target app name
    let confidence: Double          // 0.0–1.0
    let reasoning: String           // "User typically opens Slack after screen unlock in the morning"
    let source: PredictionSource
    let timestamp: Date
    var actualAction: String?       // Filled in after the fact
    var wasCorrect: Bool?           // Filled in after evaluation

    enum PredictionSource: String, Codable {
        case temporal    // Time-of-day / day-of-week pattern
        case sequence    // N-gram action sequence
        case contextual  // Embedding-based similarity
        case goal        // Goal-driven prediction
    }

    init(action: String, app: String? = nil, confidence: Double, reasoning: String, source: PredictionSource) {
        self.id = UUID()
        self.predictedAction = action
        self.predictedApp = app
        self.confidence = confidence
        self.reasoning = reasoning
        self.source = source
        self.timestamp = Date()
    }
}

/// A detected time-based routine.
struct Routine: Codable, Identifiable {
    let id: UUID
    var description: String          // "Opens Mail at 9:00 AM on weekdays"
    let triggerType: TriggerType
    let triggerValue: String         // "09:00:weekday" or "after:screen_unlock"
    var actionDescription: String    // "Open Mail"
    var targetApp: String?
    var frequency: Int               // How many times observed
    var confidence: Double
    var lastTriggered: Date?

    enum TriggerType: String, Codable {
        case timeOfDay      // "09:00"
        case dayOfWeek      // "monday"
        case afterEvent     // "after:screen_unlock"
        case appSequence    // "after:Safari"
    }

    init(description: String, triggerType: TriggerType, triggerValue: String, actionDescription: String, targetApp: String? = nil) {
        self.id = UUID()
        self.description = description
        self.triggerType = triggerType
        self.triggerValue = triggerValue
        self.actionDescription = actionDescription
        self.targetApp = targetApp
        self.frequency = 1
        self.confidence = 0.3
    }
}
