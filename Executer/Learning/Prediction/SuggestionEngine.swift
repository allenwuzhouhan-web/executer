import Foundation

/// Converts predictions + goals into actionable suggestions.
final class SuggestionEngine {
    static let shared = SuggestionEngine()

    private var pendingSuggestions: [Suggestion] = []
    private var dismissedTopics: Set<String> = []   // Don't re-suggest for 24h
    private var lastSuggestionTime: Date = .distantPast
    private let lock = NSLock()

    /// Minimum interval between suggestions (respect user focus).
    private let cooldownInterval: TimeInterval = 600 // 10 minutes

    private init() {}

    /// Generate suggestions from current predictions and goals.
    func generateSuggestions() -> [Suggestion] {
        let now = Date()
        guard now.timeIntervalSince(lastSuggestionTime) > cooldownInterval else { return [] }

        var suggestions: [Suggestion] = []

        // 1. Routine-based suggestions
        let predictions = PredictionEngine.shared.predict()
        for pred in predictions where pred.confidence > 0.6 && pred.source == .temporal {
            if !dismissedTopics.contains(pred.predictedAction) {
                suggestions.append(Suggestion(
                    text: pred.reasoning,
                    actionCommand: pred.predictedApp.map { "open \($0)" },
                    confidence: pred.confidence,
                    type: .routine
                ))
            }
        }

        // 2. Goal deadline suggestions
        let alerts = DeadlineAwareness.generateAlerts()
        for alert in alerts.prefix(2) {
            if !dismissedTopics.contains(alert) {
                suggestions.append(Suggestion(
                    text: alert,
                    confidence: 0.9,
                    type: .deadlineAlert,
                    expiresIn: 3600
                ))
            }
        }

        // Sort by confidence, take top 3
        suggestions.sort { $0.confidence > $1.confidence }
        let top = Array(suggestions.prefix(3))

        lock.lock()
        pendingSuggestions = top
        if !top.isEmpty { lastSuggestionTime = now }
        lock.unlock()

        return top
    }

    /// Get pending suggestions (not expired).
    func pending() -> [Suggestion] {
        lock.lock()
        defer { lock.unlock() }
        return pendingSuggestions.filter { !$0.isExpired }
    }

    /// Record user's response to a suggestion.
    func recordOutcome(_ suggestionId: UUID, outcome: Suggestion.SuggestionOutcome) {
        lock.lock()
        if let idx = pendingSuggestions.firstIndex(where: { $0.id == suggestionId }) {
            pendingSuggestions[idx].outcome = outcome
            if outcome == .dismissed {
                dismissedTopics.insert(pendingSuggestions[idx].text)
                // Clear dismissed topics after 24h
                DispatchQueue.main.asyncAfter(deadline: .now() + 86400) { [weak self] in
                    self?.lock.lock()
                    self?.dismissedTopics.remove(self?.pendingSuggestions[idx].text ?? "")
                    self?.lock.unlock()
                }
            }
        }
        lock.unlock()
    }
}
