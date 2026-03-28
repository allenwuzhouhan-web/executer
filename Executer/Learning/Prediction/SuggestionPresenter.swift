import Foundation

/// Decides when and how to present suggestions.
/// Respects user focus — NEVER steals focus or shows windows during active work.
enum SuggestionPresenter {

    /// Check if now is a good time to show a suggestion.
    /// Returns the best suggestion to show, or nil if not appropriate.
    static func checkForSuggestion() -> Suggestion? {
        let suggestions = SuggestionEngine.shared.generateSuggestions()

        // Only show if there's a high-confidence suggestion
        guard let best = suggestions.first, best.confidence > 0.6 else { return nil }

        return best
    }

    /// Format a suggestion for display in the input bar placeholder.
    static func formatForPlaceholder(_ suggestion: Suggestion) -> String {
        switch suggestion.type {
        case .routine:
            return "💡 \(suggestion.text)"
        case .deadlineAlert:
            return "⏰ \(suggestion.text)"
        case .goalReminder:
            return "🎯 \(suggestion.text)"
        case .workflowHint:
            return "⚡ \(suggestion.text)"
        }
    }
}
