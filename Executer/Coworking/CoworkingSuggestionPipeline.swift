import Foundation
import EventKit

/// Evaluates whether to offer the user a proactive suggestion.
///
/// Called on-demand by CoworkerAgent (not per-event). Reuses existing SuggestionEngine
/// and ProactiveSuggestionEngine, adds local heuristics, and falls back to a rate-limited
/// LLM batch evaluation only when nothing else triggers.
actor CoworkingSuggestionPipeline {
    static let shared = CoworkingSuggestionPipeline()

    // MARK: - Configuration

    /// Minimum seconds between LLM-based evaluations (expensive).
    /// Increased from 5min to 15min by foveal attention Stage 3 gating.
    private let llmEvalInterval: TimeInterval = 900  // 15 min (was 5 min)

    /// Maximum pending suggestions to hold.
    private let maxPending = 2

    /// Minimum confidence to surface.
    private let minConfidence = 0.5

    // MARK: - Anti-spam State

    private var consecutiveDismissals: Int = 0
    private var perTypeCooldown: [CoworkingSuggestion.SuggestionType: Date] = [:]
    private let perTypeCooldownDuration: TimeInterval = 1800  // 30 min after dismissal

    /// Exponential backoff multiplier for the eval interval.
    private var backoffMultiplier: Double = 1.0
    private let maxBackoffMinutes: TimeInterval = 3600  // 60 min cap

    private var lastLLMEvalTime: Date = .distantPast

    // MARK: - Evaluation

    /// Main evaluation entry point. Returns the best suggestion, or nil.
    func evaluate(state: WorkState) async -> CoworkingSuggestion? {
        // Gate: blocked focus modes (already checked by InterruptionPolicy, but double-check)
        switch state.focusMode {
        case .doNotDisturb, .sleep, .driving, .mindfulness:
            return nil
        default:
            break
        }

        // Gate: backoff from consecutive dismissals
        let effectiveCooldown = 120.0 * backoffMultiplier  // Base: 2 min, doubled per dismissal streak
        // (The orchestrator's loop interval handles most throttling; this is a secondary gate)

        // 1. Reuse existing SuggestionEngine (synchronous, no LLM)
        let basicSuggestions = SuggestionEngine.shared.generateSuggestions()
        if let best = basicSuggestions.first, best.confidence > minConfidence {
            let converted = convertBasicSuggestion(best)
            if !isCoolingDown(type: converted.type) {
                return converted
            }
        }

        // 2. Reuse ProactiveSuggestionEngine (async, no LLM)
        let workflowSuggestions = await ProactiveSuggestionEngine.shared.generateSuggestions()
        if let best = workflowSuggestions.first, best.confidence > minConfidence {
            let converted = convertWorkflowSuggestion(best)
            if !isCoolingDown(type: converted.type) {
                return converted
            }
        }

        // 2.5. Workflow Compression — suggest automating detected repetitive patterns
        if !isCoolingDown(type: .workflowAutomation),
           let pattern = await WorkflowCompressionBridge.shared.nextCandidate() {
            let stepPreview = pattern.actions.prefix(4).map { $0.elementTitle }.joined(separator: " → ")
            let more = pattern.actions.count > 4 ? " → …" : ""
            return CoworkingSuggestion(
                type: .workflowAutomation,
                headline: "You do \"\(pattern.name)\" \(pattern.frequency)x — automate it?",
                detail: stepPreview + more,
                actionCommand: "__compress_workflow:\(pattern.id.uuidString)",
                confidence: min(0.9, 0.5 + Double(pattern.frequency) / 20.0),
                expiresIn: 600
            )
        }

        // 3. Local heuristic checks (no LLM)
        if let heuristic = checkLocalHeuristics(state: state) {
            if !isCoolingDown(type: heuristic.type) {
                return heuristic
            }
        }

        // 3.7. Synthesis Engine — cross-domain connections (rate-limited by engine's 30-min cycle)
        if state.idleSeconds > 30, !isCoolingDown(type: .synthesis) {
            if let insight = await SynthesisEngine.shared.nextPendingInsight() {
                return CoworkingSuggestion(
                    type: .synthesis,
                    headline: insight.headline,
                    detail: insight.explanation,
                    actionCommand: insight.actionSuggestion,
                    confidence: insight.surpriseScore,
                    expiresIn: 600  // 10 min — higher value since these are rarer and more valuable
                )
            }
        }

        // 4. LLM batch evaluation (expensive, rate-limited)
        let now = Date()
        if now.timeIntervalSince(lastLLMEvalTime) > llmEvalInterval {
            lastLLMEvalTime = now
            if let llmSuggestion = await llmBatchEvaluate(state: state) {
                if !isCoolingDown(type: llmSuggestion.type) {
                    return llmSuggestion
                }
            }
        }

        return nil
    }

    // MARK: - Feedback

    /// Record user response to a suggestion. Drives adaptive throttling.
    func recordFeedback(accepted: Bool, type: CoworkingSuggestion.SuggestionType) {
        if accepted {
            consecutiveDismissals = 0
            backoffMultiplier = 1.0
        } else {
            consecutiveDismissals += 1
            perTypeCooldown[type] = Date()
            if consecutiveDismissals >= 3 {
                backoffMultiplier = min(backoffMultiplier * 2.0, maxBackoffMinutes / 120.0)
            }
        }
    }

    /// Record that a suggestion expired without any interaction (soft dismissal).
    func recordExpiry(type: CoworkingSuggestion.SuggestionType) {
        // Half-weight toward dismissal tracking
        if consecutiveDismissals > 0 || Bool.random() {
            consecutiveDismissals += 1
        }
        if consecutiveDismissals >= 3 {
            backoffMultiplier = min(backoffMultiplier * 1.5, maxBackoffMinutes / 120.0)
        }
    }

    /// Current effective evaluation interval (accounts for backoff).
    var effectiveEvalInterval: TimeInterval {
        return 30.0 * backoffMultiplier  // Base: 30s
    }

    // MARK: - Per-Type Cooldown

    private func isCoolingDown(type: CoworkingSuggestion.SuggestionType) -> Bool {
        guard let lastDismissal = perTypeCooldown[type] else { return false }
        return Date().timeIntervalSince(lastDismissal) < perTypeCooldownDuration
    }

    // MARK: - Convert Existing Suggestions

    private func convertBasicSuggestion(_ s: Suggestion) -> CoworkingSuggestion {
        let type: CoworkingSuggestion.SuggestionType
        switch s.type {
        case .routine: type = .routine
        case .deadlineAlert: type = .deadlineAlert
        case .goalReminder: type = .goalNudge
        case .workflowHint: type = .workflowAutomation
        }
        return CoworkingSuggestion(
            type: type,
            headline: s.text,
            actionCommand: s.actionCommand,
            confidence: s.confidence
        )
    }

    private func convertWorkflowSuggestion(_ s: WorkflowSuggestion) -> CoworkingSuggestion {
        let type: CoworkingSuggestion.SuggestionType
        switch s.type {
        case .temporalRoutine: type = .routine
        case .calendarPrep: type = .meetingPrep
        case .repetitionDetected: type = .workflowAutomation
        case .goalDeadline: type = .goalNudge
        }
        return CoworkingSuggestion(
            type: type,
            headline: s.message,
            detail: s.reason,
            actionCommand: "run workflow \(s.workflow.name)",
            confidence: s.confidence
        )
    }

    // MARK: - Local Heuristics

    /// Checks all local heuristics in priority order. Returns the first match.
    private func checkLocalHeuristics(state: WorkState) -> CoworkingSuggestion? {
        // Priority order: meeting prep > workspace focus > break > clipboard > files > context switch
        if let s = checkMeetingPrep() { return s }
        if let s = checkWorkspaceFocus(state: state) { return s }
        if let s = checkBreakReminder(state: state) { return s }
        if let s = checkClipboardEnrichment(state: state) { return s }
        if let s = checkFileContext(state: state) { return s }
        if let s = checkContextSwitchStorm(state: state) { return s }
        if let s = checkContextualAwareness() { return s }
        return nil
    }

    // MARK: - Meeting Prep

    /// Track which events we've already suggested for (by event identifier).
    private var suggestedMeetingIDs: Set<String> = []

    private func checkMeetingPrep() -> CoworkingSuggestion? {
        guard let event = CalendarCorrelator.shared.nextUpcomingEvent(withinHours: 0.25) else {
            return nil  // No event in next 15 min
        }

        let eventId = event.eventIdentifier ?? event.title ?? ""
        guard !suggestedMeetingIDs.contains(eventId) else { return nil }
        suggestedMeetingIDs.insert(eventId)

        let title = event.title ?? "Upcoming event"
        let minutesUntil = max(1, Int(event.startDate.timeIntervalSinceNow / 60))

        // Enrich with related goals for a more useful suggestion
        let snapshot = MeetingIntelligence.CalendarEventSnapshot(from: event)
        let goals = GoalTracker.shared.topGoals(limit: 5)
        let relatedGoals = goals.filter { goal in
            snapshot.keywords.contains(where: { goal.topic.lowercased().contains($0) })
        }
        let goalHint = relatedGoals.isEmpty ? "" : " Related goals: \(relatedGoals.map(\.topic).joined(separator: ", "))."

        return CoworkingSuggestion(
            type: .meetingPrep,
            headline: "'\(title)' starts in \(minutesUntil) min — want a quick prep summary?",
            detail: "I can pull together your recent notes and goals related to this.\(goalHint)",
            actionCommand: "Prepare a brief status summary for my meeting: \(title)",
            confidence: 0.8,
            expiresIn: Double(minutesUntil * 60)
        )
    }

    // MARK: - Break Reminder (graduated)

    private func checkBreakReminder(state: WorkState) -> CoworkingSuggestion? {
        guard state.activityType != .idle else { return nil }
        let minutes = Int(state.activityDuration / 60)

        if state.activityDuration > 10800 {
            // 3+ hours
            return CoworkingSuggestion(
                type: .breakReminder,
                headline: "\(minutes / 60) hours of \(state.activityType.rawValue) — want me to set a 5-min break timer?",
                actionCommand: "set timer 5 minutes break",
                confidence: 0.7,
                expiresIn: 600
            )
        } else if state.activityDuration > 5400 {
            // 90+ min
            return CoworkingSuggestion(
                type: .breakReminder,
                headline: "You've been at it for \(minutes) min. Good time for a quick stretch?",
                confidence: 0.5,
                expiresIn: 600
            )
        }

        return nil
    }

    // MARK: - Clipboard Enrichment

    private func checkClipboardEnrichment(state: WorkState) -> CoworkingSuggestion? {
        guard state.recentClipboardFlows > 0 else { return nil }
        let preview = state.lastClipboardPreview
        guard !preview.isEmpty else { return nil }

        // URL detection: starts with http or contains common URL patterns
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return CoworkingSuggestion(
                type: .clipboardAssist,
                headline: "You copied a link — want me to fetch the title and summary?",
                detail: String(trimmed.prefix(60)),
                actionCommand: "Fetch and summarize this URL from my clipboard",
                confidence: 0.6,
                expiresIn: 300
            )
        }

        // Short text lookup: < 50 chars, user is reading or writing
        let lookupActivities: Set<WorkState.ActivityType> = [.writing, .reading, .browsing]
        if trimmed.count < 50 && trimmed.count > 2 && lookupActivities.contains(state.activityType) {
            return CoworkingSuggestion(
                type: .clipboardAssist,
                headline: "You copied '\(trimmed)' — want me to look it up?",
                actionCommand: "Look up: \(trimmed)",
                confidence: 0.55,
                expiresIn: 300
            )
        }

        return nil
    }

    // MARK: - File Context

    private func checkFileContext(state: WorkState) -> CoworkingSuggestion? {
        let extensions = state.recentFileExtensions
        guard extensions.count >= 3 else { return nil }

        // Count by extension to detect clusters
        var extCounts: [String: Int] = [:]
        for ext in extensions { extCounts[ext, default: 0] += 1 }

        if let (ext, count) = extCounts.max(by: { $0.value < $1.value }), count >= 3 {
            return CoworkingSuggestion(
                type: .fileOrganization,
                headline: "\(count) new .\(ext) files detected — want me to organize or summarize them?",
                actionCommand: "List and summarize the recent \(ext) files in my Downloads folder",
                confidence: 0.55,
                expiresIn: 600
            )
        }

        return nil
    }

    // MARK: - Workspace Focus

    private func checkWorkspaceFocus(state: WorkState) -> CoworkingSuggestion? {
        return nil
    }

    // MARK: - Context Switch Storm

    private func checkContextSwitchStorm(state: WorkState) -> CoworkingSuggestion? {
        let uniqueApps = Set(state.recentApps.map(\.name)).count
        guard uniqueApps >= 5 else { return nil }

        return CoworkingSuggestion(
            type: .contextualHelp,
            headline: "Lots of context switching (\(uniqueApps) apps in 10 min) — want me to help you focus?",
            detail: "I can organize your windows and suggest what to prioritize.",
            actionCommand: """
                First, use list_windows to see all open windows. Then use arrange_windows to tile \
                the visible app windows into a clean, focused layout. \
                After organizing, list exactly 5 specific, actionable things I can do right now to \
                speed up the user's workflow based on the open apps and their goals. \
                Keep each suggestion to one sentence.
                """,
            confidence: 0.6,
            expiresIn: 600
        )
    }

    // MARK: - ContextualAwareness Integration

    private var lastContextualCheck: Date = .distantPast

    private func checkContextualAwareness() -> CoworkingSuggestion? {
        // Rate-limit: don't check more than once per 10 min
        guard Date().timeIntervalSince(lastContextualCheck) > 600 else { return nil }
        lastContextualCheck = Date()

        // ContextualAwareness.checkContext() is async, but we're already in an actor.
        // Use the sync check methods directly for relevant nudges.
        // For now, we skip the async calendar check (already handled by checkMeetingPrep).
        return nil
    }

    // MARK: - LLM Batch Evaluation

    /// Previous work state embedding for drift detection (Stage 3 gate).
    private var previousWorkStateEmbedding: [Double]?

    private func llmBatchEvaluate(state: WorkState) async -> CoworkingSuggestion? {
        let goalContext = GoalStack.promptSection
        let stateDesc = """
        Current app: \(state.currentApp)
        Activity: \(state.activityType.rawValue) for \(Int(state.activityDuration / 60)) min
        Focus mode: \(state.focusMode.displayName)
        Recent clipboard flows: \(state.recentClipboardFlows)
        Recent file events: \(state.recentFileEvents)
        Idle: \(Int(state.idleSeconds))s
        """

        // Stage 3 drift gate: skip LLM if work state hasn't meaningfully changed
        if !FovealRouter.shouldCallAPI(
            currentSnapshot: stateDesc,
            previousEmbedding: &previousWorkStateEmbedding,
            driftThreshold: 0.7
        ) {
            print("[CoworkingPipeline] Drift gate: state unchanged, skipping LLM eval")
            return nil
        }

        // Use Stage 3 macula micro-prompt (compact, ~200 tokens instead of ~500)
        let prompt = ContextCompressor.maculaCoworkingPrompt(state: stateDesc, goals: goalContext)

        let messages = [
            ChatMessage(role: "user", content: prompt, tool_calls: nil, tool_call_id: nil, reasoning_content: nil)
        ]

        do {
            let service = LLMServiceManager.shared.currentService
            let response = try await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 150)
            guard let text = response.text else { return nil }
            return parseLLMSuggestion(text)
        } catch {
            print("[CoworkingPipeline] LLM eval failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseLLMSuggestion(_ text: String) -> CoworkingSuggestion? {
        // Extract JSON from response (handle markdown fences)
        var jsonStr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonStr.range(of: "{"), let end = jsonStr.range(of: "}", options: .backwards) {
            jsonStr = String(jsonStr[start.lowerBound...end.lowerBound])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let suggest = json["suggest"] as? Bool, suggest,
              let headline = json["headline"] as? String else {
            return nil
        }

        let typeStr = json["type"] as? String ?? "contextualHelp"
        let type = CoworkingSuggestion.SuggestionType(rawValue: typeStr) ?? .contextualHelp
        let confidence = json["confidence"] as? Double ?? 0.6
        let action = json["action"] as? String

        return CoworkingSuggestion(
            type: type,
            headline: headline,
            actionCommand: action,
            confidence: confidence,
            expiresIn: 300
        )
    }
}
