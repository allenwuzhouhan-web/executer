import Foundation

/// Tracks suggestion acceptance rates for improvement.
enum SuggestionFeedback {

    private static var history: [(suggestion: Suggestion, outcome: Suggestion.SuggestionOutcome, timestamp: Date)] = []

    /// Record a suggestion outcome.
    static func record(suggestion: Suggestion, outcome: Suggestion.SuggestionOutcome) {
        history.append((suggestion, outcome, Date()))
        // Keep last 500 entries
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
    }

    /// Overall acceptance rate.
    static func acceptanceRate() -> Double {
        guard !history.isEmpty else { return 0 }
        let accepted = history.filter { $0.outcome == .accepted }.count
        return Double(accepted) / Double(history.count)
    }

    /// Acceptance rate by suggestion type.
    static func acceptanceRateByType() -> [Suggestion.SuggestionType: Double] {
        let grouped = Dictionary(grouping: history, by: \.suggestion.type)
        return grouped.mapValues { entries in
            let accepted = entries.filter { $0.outcome == .accepted }.count
            return Double(accepted) / Double(entries.count)
        }
    }

    /// Summary for reporting.
    static func summary() -> String {
        let rate = acceptanceRate()
        return "Suggestion acceptance rate: \(String(format: "%.1f%%", rate * 100)) over \(history.count) suggestions"
    }
}
