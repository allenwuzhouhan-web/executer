import Foundation

/// A suggestion from the Coworking Agent to the user.
/// Lightweight, Sendable data model — the pipeline creates these, the UI renders them.
struct CoworkingSuggestion: Identifiable, Sendable {
    let id: UUID
    let type: SuggestionType
    let headline: String            // One line: "Meeting in 10 min — want a status summary?"
    let detail: String?             // Optional second line with context
    let actionCommand: String?      // If accepted, submit this to AgentLoop
    let confidence: Double          // 0.0–1.0
    let createdAt: Date
    let expiresAt: Date

    var isExpired: Bool { Date() > expiresAt }

    enum SuggestionType: String, Sendable, CaseIterable {
        case goalNudge           // "Your essay deadline is tomorrow — want to work on the outline?"
        case meetingPrep         // "Standup in 10 min — want a status summary?"
        case breakReminder       // "You've been coding for 3 hours. Time for a break?"
        case clipboardAssist     // "You copied a URL — want me to fetch the title?"
        case fileOrganization    // "3 new PDFs in Downloads. Want me to sort them?"
        case workflowAutomation  // "You've done this 5x manually — automate it?"
        case contextualHelp      // "Looks like you're stuck on a compile error."
        case routine             // "You usually check email around now."
        case deadlineAlert       // "Assignment due in 4 hours."
        case synthesis           // Cross-domain connection: "Your research connects to Thursday's deadline"
        case workspaceFocus      // Organize windows + list productivity actions
    }

    init(
        type: SuggestionType,
        headline: String,
        detail: String? = nil,
        actionCommand: String? = nil,
        confidence: Double,
        expiresIn: TimeInterval = 300  // Default: 5 min expiry
    ) {
        self.id = UUID()
        self.type = type
        self.headline = headline
        self.detail = detail
        self.actionCommand = actionCommand
        self.confidence = confidence
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(expiresIn)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let coworkingSuggestionAvailable = Notification.Name("com.executer.coworking.suggestionAvailable")
    static let coworkingSuggestionDismissed = Notification.Name("com.executer.coworking.suggestionDismissed")
    static let coworkerAgentStateChanged = Notification.Name("com.executer.coworking.stateChanged")
}
