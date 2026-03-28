import Foundation

/// A proactive suggestion surfaced to the user.
struct Suggestion: Codable, Identifiable {
    let id: UUID
    let text: String                 // "You usually check email around now"
    let actionCommand: String?       // Command to execute if accepted: "open Mail"
    let confidence: Double
    let type: SuggestionType
    let expiresAt: Date              // Don't show after this time
    var outcome: SuggestionOutcome?
    let createdAt: Date

    enum SuggestionType: String, Codable {
        case routine          // Time-based routine
        case goalReminder     // Goal deadline approaching
        case workflowHint     // Learned workflow suggestion
        case deadlineAlert    // Urgent deadline
    }

    enum SuggestionOutcome: String, Codable {
        case accepted
        case dismissed
        case ignored    // Expired without interaction
        case expired
    }

    init(text: String, actionCommand: String? = nil, confidence: Double, type: SuggestionType, expiresIn: TimeInterval = 1800) {
        self.id = UUID()
        self.text = text
        self.actionCommand = actionCommand
        self.confidence = confidence
        self.type = type
        self.expiresAt = Date().addingTimeInterval(expiresIn)
        self.createdAt = Date()
    }

    var isExpired: Bool { Date() > expiresAt }
}
