import Foundation

/// Workflow-aware proactive suggestion engine.
///
/// Phase 14 of the Workflow Recorder ("The Oracle").
/// Extends the existing SuggestionEngine with workflow intelligence:
/// - Temporal routines matched to stored workflows
/// - Real-time repetition detection ("you've been doing this manually...")
/// - Calendar-linked pre-event workflows
/// - Suggestion feedback learning (accept/dismiss rate tracking)
actor ProactiveSuggestionEngine {
    static let shared = ProactiveSuggestionEngine()

    // MARK: - Configuration

    private let minConfidence = 0.4
    private let suggestionCooldown: TimeInterval = 600  // 10 minutes
    private let maxPendingSuggestions = 3

    // MARK: - State

    private var pendingSuggestions: [WorkflowSuggestion] = []
    private var lastSuggestionTime: [String: Date] = [:]
    private var feedbackHistory: [UUID: WorkflowSuggestionOutcome] = [:]

    private let repetitionDetector = RepetitionDetector()

    // MARK: - Suggestion Generation

    func generateSuggestions() async -> [WorkflowSuggestion] {
        var suggestions: [WorkflowSuggestion] = []

        let temporalSuggestions = await generateTemporalSuggestions()
        suggestions.append(contentsOf: temporalSuggestions)

        let calendarSuggestions = await generateCalendarSuggestions()
        suggestions.append(contentsOf: calendarSuggestions)

        let repetitionSuggestions = await generateRepetitionSuggestions()
        suggestions.append(contentsOf: repetitionSuggestions)

        suggestions = suggestions.filter { suggestion in
            guard suggestion.confidence >= minConfidence else { return false }
            let key = suggestion.typeKey
            if let lastTime = lastSuggestionTime[key],
               Date().timeIntervalSince(lastTime) < suggestionCooldown {
                return false
            }
            return true
        }

        suggestions.sort { $0.confidence > $1.confidence }
        suggestions = Array(suggestions.prefix(maxPendingSuggestions))

        pendingSuggestions = suggestions
        return suggestions
    }

    // MARK: - Temporal Suggestions

    private func generateTemporalSuggestions() async -> [WorkflowSuggestion] {
        let workflows = await WorkflowRepository.shared.allWorkflows(limit: 50)
        guard !workflows.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentWeekday = calendar.component(.weekday, from: now)

        let routines = PredictionEngine.shared.getRoutines()
        var suggestions: [WorkflowSuggestion] = []

        for routine in routines {
            let targetApp = routine.targetApp ?? ""
            let matchingWorkflows = workflows.filter { wf in
                wf.applicability.primaryApp.lowercased() == targetApp.lowercased() ||
                wf.name.lowercased().contains(String(routine.description.lowercased().prefix(20)))
            }

            guard let bestMatch = matchingWorkflows.first else { continue }

            let isTimeMatch: Bool
            switch routine.triggerType {
            case .timeOfDay:
                let hourStr = routine.triggerValue.split(separator: ":").first.flatMap { Int($0) }
                isTimeMatch = hourStr == currentHour
            case .dayOfWeek:
                // triggerValue is "monday", "tuesday", etc. (see PredictionModel.swift)
                let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
                let triggerLower = routine.triggerValue.lowercased()
                if let dayIndex = dayNames.firstIndex(of: triggerLower) {
                    // Calendar weekday: Sunday=1, Monday=2, ...
                    isTimeMatch = (dayIndex + 1) == currentWeekday
                } else {
                    // Fallback: try "day:hour" numeric format
                    let parts = routine.triggerValue.split(separator: ":")
                    if parts.count >= 2, let day = Int(parts[0]), let hour = Int(parts[1]) {
                        isTimeMatch = day == currentWeekday && hour == currentHour
                    } else {
                        isTimeMatch = false
                    }
                }
            case .afterEvent, .appSequence:
                isTimeMatch = false
            }

            if isTimeMatch {
                suggestions.append(WorkflowSuggestion(
                    type: .temporalRoutine,
                    workflow: bestMatch,
                    message: "It's \(formatTime(now)) — run '\(bestMatch.name)'?",
                    confidence: routine.confidence,
                    reason: "You usually do this at this time (\(routine.frequency)x observed)"
                ))
            }
        }

        return suggestions
    }

    // MARK: - Calendar Suggestions

    private func generateCalendarSuggestions() async -> [WorkflowSuggestion] {
        guard let nextEvent = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 1) else {
            return []
        }

        let eventTitle = nextEvent.title ?? "Upcoming event"
        let workflows = await WorkflowRepository.shared.allWorkflows(limit: 50)

        let eventKeywords = Set(eventTitle.lowercased().split(separator: " ").map(String.init))
        let matches = workflows.filter { wf in
            let wfKeywords = Set(wf.applicability.keywords.map { $0.lowercased() })
            return !wfKeywords.intersection(eventKeywords).isEmpty
        }

        guard let bestMatch = matches.first else { return [] }

        let minutesUntil = Int(nextEvent.startDate.timeIntervalSince(Date()) / 60)

        return [WorkflowSuggestion(
            type: .calendarPrep,
            workflow: bestMatch,
            message: "'\(eventTitle)' in \(minutesUntil) min — run '\(bestMatch.name)' to prepare?",
            confidence: 0.6,
            reason: "You typically run this before similar events"
        )]
    }

    // MARK: - Repetition Suggestions

    private func generateRepetitionSuggestions() async -> [WorkflowSuggestion] {
        guard let repeating = await repetitionDetector.currentRepetition() else { return [] }

        let query = repeating.actions.map(\.semanticAction).joined(separator: " ")
        let matches = await WorkflowRepository.shared.search(query: query, limit: 3)

        if let bestMatch = matches.first {
            return [WorkflowSuggestion(
                type: .repetitionDetected,
                workflow: bestMatch.workflow,
                message: "You've done '\(repeating.description)' \(repeating.count)x — want me to handle the rest?",
                confidence: min(Double(repeating.count) / 5.0, 0.9),
                reason: "Detected \(repeating.count) repetitions of the same \(repeating.actions.count)-step sequence"
            )]
        }

        return []
    }

    // MARK: - Feedback

    func recordFeedback(_ suggestionId: UUID, accepted: Bool) {
        feedbackHistory[suggestionId] = WorkflowSuggestionOutcome(
            suggestionId: suggestionId,
            accepted: accepted,
            timestamp: Date()
        )

        if let suggestion = pendingSuggestions.first(where: { $0.id == suggestionId }) {
            if !accepted {
                lastSuggestionTime[suggestion.typeKey] = Date()
            }
        }

        // Keep last 200
        if feedbackHistory.count > 200 {
            let oldest = feedbackHistory.sorted { $0.value.timestamp < $1.value.timestamp }
            for entry in oldest.prefix(feedbackHistory.count - 200) {
                feedbackHistory.removeValue(forKey: entry.key)
            }
        }
    }

    func acceptRate() -> Double {
        guard !feedbackHistory.isEmpty else { return 0.5 }
        let accepted = feedbackHistory.values.filter { $0.accepted }.count
        return Double(accepted) / Double(feedbackHistory.count)
    }

    // MARK: - Repetition Detection Feed

    func feedEvent(_ event: ObservationEvent) async {
        if case .userAction(let action) = event {
            let entry = JournalEntry(
                semanticAction: "\(action.type.rawValue) \(action.elementTitle)",
                appContext: action.appName,
                elementContext: action.elementRole,
                intentCategory: "unknown",
                sourceType: .userAction,
                topicTerms: [action.appName],
                confidence: 0.5
            )
            await repetitionDetector.feed(entry)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Repetition Detector

actor RepetitionDetector {
    private var recentEntries: [JournalEntry] = []
    private let maxHistory = 100
    private let minSequenceLength = 3
    private let minRepetitions = 2

    func feed(_ entry: JournalEntry) {
        recentEntries.append(entry)
        if recentEntries.count > maxHistory {
            recentEntries.removeFirst(recentEntries.count - maxHistory)
        }
    }

    func currentRepetition() -> RepetitionPattern? {
        guard recentEntries.count >= minSequenceLength * minRepetitions else { return nil }

        for seqLen in minSequenceLength...min(8, recentEntries.count / 2) {
            let lastSeq = recentEntries.suffix(seqLen)
            let signatures = lastSeq.map { "\($0.appContext):\($0.intentCategory):\($0.elementContext)" }

            var count = 0
            var i = recentEntries.count - seqLen

            while i >= 0 {
                let candidate = recentEntries[i..<(i + seqLen)]
                let candidateSigs = candidate.map { "\($0.appContext):\($0.intentCategory):\($0.elementContext)" }

                if candidateSigs == signatures {
                    count += 1
                    i -= seqLen
                } else {
                    break
                }
            }

            if count >= minRepetitions {
                return RepetitionPattern(
                    actions: Array(lastSeq),
                    count: count,
                    description: lastSeq.first?.semanticAction ?? "repeated action"
                )
            }
        }

        return nil
    }

    func reset() {
        recentEntries.removeAll()
    }
}

// MARK: - Models

struct WorkflowSuggestion: Identifiable, Sendable {
    let id: UUID = UUID()
    let type: SuggestionType
    let workflow: GeneralizedWorkflow
    let message: String
    let confidence: Double
    let reason: String

    var typeKey: String { "\(type.rawValue):\(workflow.id)" }

    enum SuggestionType: String, Sendable {
        case temporalRoutine
        case calendarPrep
        case repetitionDetected
        case goalDeadline
    }
}

struct WorkflowSuggestionOutcome: Sendable {
    let suggestionId: UUID
    let accepted: Bool
    let timestamp: Date
}

struct RepetitionPattern: Sendable {
    let actions: [JournalEntry]
    let count: Int
    let description: String
}
