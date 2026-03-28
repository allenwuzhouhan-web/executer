import Foundation

/// Drafts messages in the user's communication style.
/// ALWAYS requires approval before sending — this cannot be overridden.
enum CommunicationProxy {

    /// Draft a message based on user's typical style.
    static func draftMessage(context: String, recipient: String) -> String {
        // Placeholder — in production, this would use the LLM with the user's
        // communication style from WorkProfile
        return "Draft message to \(recipient) about: \(context)"
    }

    /// Drafts always require approval. This is a hard safety limit.
    static var alwaysRequiresApproval: Bool { true }
}
