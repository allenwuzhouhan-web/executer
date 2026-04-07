import Foundation

/// Real-time cross-app correlation engine that consumes the observation stream
/// and produces insights by connecting activity across multiple apps.
///
/// Complements the existing `SynthesisEngine` (deep LLM-based synthesis, hourly)
/// with fast stream-based correlation (every 60s when new observations arrive).
///
/// Three modes:
/// 1. **Cross-app fusion** — links concurrent activity across 2+ apps
/// 2. **Research aggregation** — correlates browser trails + app observations
/// 3. **Project rollup** — multi-session status from journal history (on-demand)
actor CrossAppSynthesizer {
    static let shared = CrossAppSynthesizer()

    // MARK: - State

    /// Sliding window of recent observations (pruned to windowDuration).
    private var recentObservations: [SemanticObservation] = []

    /// Currently active insights (recent, not yet expired).
    private var activeInsights: [CrossAppInsight] = []

    /// History of past insights (capped at maxHistory).
    private var insightHistory: [CrossAppInsight] = []

    /// Tracks whether new observations arrived since last synthesis pass.
    private var hasNewData = false

    /// Background synthesis loop task.
    private var synthesisTask: Task<Void, Never>?

    /// Drift detection: skip LLM when context hasn't meaningfully changed.
    private var previousFusionEmbedding: [Double]?

    /// Meeting state tracking for post-meeting synthesis triggers.
    private var lastMeetingPhase: MeetingIntelligence.MeetingState.MeetingPhase = .none
    private var lastMeetingEvent: MeetingIntelligence.CalendarEventSnapshot?

    // MARK: - Configuration

    private let windowDuration: TimeInterval = 30 * 60       // 30 min sliding window
    private let synthesisInterval: TimeInterval = 60          // run every 60s
    private let minAppsForFusion = 2                          // 2+ apps = cross-app fusion
    private let minSourcesForResearch = 3                     // 3+ browser sources = research agg
    private let maxActiveInsights = 10
    private let maxHistory = 50
    private let insightTTL: TimeInterval = 15 * 60            // insights expire after 15 min

    // MARK: - Lifecycle

    /// Register as a consumer of the observation stream and start the synthesis loop.
    func startConsuming() async {
        await ContinuousPerceptionDaemon.shared.addConsumer(name: "cross-app-synthesis") { [weak self] event in
            await self?.ingestEvent(event)
        }
        startSynthesisLoop()
        print("[CrossAppSynthesizer] Started — consuming observation stream")
    }

    /// Stop the synthesis loop.
    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
    }

    // MARK: - Event Ingestion

    /// Ingest an observation event, converting it to SemanticObservation if possible.
    private func ingestEvent(_ event: ObservationEvent) {
        guard let observation = extractObservation(from: event) else { return }
        recentObservations.append(observation)
        hasNewData = true
        pruneWindow()
    }

    /// Extract a SemanticObservation from an ObservationEvent.
    private func extractObservation(from event: ObservationEvent) -> SemanticObservation? {
        // For screen samples, check if AttentionTracker already produced an observation
        if case .screenSample(let sample) = event {
            let recent = AttentionTracker.shared.windowedObservations(windowMinutes: 1)
            if let match = recent.first(where: { $0.observation.appName == sample.appName })?.observation {
                return match
            }
            return SemanticObservation(
                appName: sample.appName,
                category: .other,
                intent: "Active in \(sample.appName)",
                relatedTopics: []
            )
        }

        if case .oeAppEvent(let e) = event {
            return SemanticObservation(
                appName: e.appName,
                category: .other,
                intent: "Using \(e.appName)",
                relatedTopics: []
            )
        }

        if case .userAction(let a) = event {
            return SemanticObservation(
                appName: a.appName,
                category: .other,
                intent: "\(a.type.rawValue) in \(a.appName)",
                relatedTopics: []
            )
        }

        return nil
    }

    /// Remove observations outside the sliding window.
    private func pruneWindow() {
        let cutoff = Date().addingTimeInterval(-windowDuration)
        recentObservations.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Synthesis Loop

    private func startSynthesisLoop() {
        synthesisTask?.cancel()
        synthesisTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
                guard let self = self else { break }
                guard await self.hasNewData else { continue }
                await self.runSynthesisPass()
            }
        }
    }

    /// Run one pass of all synthesis modes.
    private func runSynthesisPass() async {
        hasNewData = false
        pruneWindow()
        expireOldInsights()

        // 0. Meeting state detection — check for phase transitions
        let currentApp = recentObservations.last?.appName ?? ""
        let meetingState = MeetingIntelligence.currentState(currentApp: currentApp, windowTitle: "")
        await checkMeetingTransition(newPhase: meetingState.phase, event: meetingState.currentEvent)

        // 1. Cross-app fusion (with calendar enrichment)
        if let insight = await synthesizeCrossApp() {
            addInsight(insight)
        }

        // 2. Research aggregation (only when browser activity detected)
        let browserApps: Set<String> = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser"]
        let hasBrowserActivity = recentObservations.contains { browserApps.contains($0.appName) }
        if hasBrowserActivity, let insight = await synthesizeResearch() {
            addInsight(insight)
        }
    }

    /// Detect meeting phase transitions and trigger post-meeting synthesis.
    private func checkMeetingTransition(
        newPhase: MeetingIntelligence.MeetingState.MeetingPhase,
        event: MeetingIntelligence.CalendarEventSnapshot?
    ) async {
        let oldPhase = lastMeetingPhase
        lastMeetingPhase = newPhase

        // Track the event while in meeting
        if newPhase == .active, let event = event {
            lastMeetingEvent = event
        }

        // Detect: was in meeting → no longer in meeting → trigger post-meeting synthesis
        if oldPhase == .active && newPhase != .active, let event = lastMeetingEvent {
            let postData = MeetingIntelligence.gatherPostMeetingData(event: event)
            if !postData.isEmpty {
                let insight = CrossAppInsight(
                    id: UUID(), timestamp: Date(),
                    type: .crossAppFusion,
                    title: "Meeting ended: \(event.title)",
                    summary: postData,
                    sources: [],
                    connectedApps: [],
                    connectedTopics: event.keywords.map { $0 },
                    confidence: 0.9,
                    actionability: .suggestAction
                )
                addInsight(insight)
                print("[CrossAppSynthesizer] Post-meeting synthesis triggered for '\(event.title)'")
            }
            lastMeetingEvent = nil
        }
    }

    // MARK: - Cross-App Fusion

    private func synthesizeCrossApp() async -> CrossAppInsight? {
        let clusters = CrossAppCorrelator.findClusters(recentObservations, windowSeconds: windowDuration)

        guard let best = clusters
            .filter({ cluster in Set(cluster.map(\.appName)).count >= minAppsForFusion })
            .max(by: { $0.count < $1.count }) else {
            return nil
        }

        let apps = Array(Set(best.map(\.appName)).sorted())
        let topics = Array(Set(best.flatMap(\.relatedTopics)).prefix(10))

        // Skip if we already have a recent fusion insight with the same apps
        if activeInsights.contains(where: {
            $0.type == .crossAppFusion && Set($0.connectedApps) == Set(apps)
        }) {
            return nil
        }

        // Drift gate: skip LLM if observations haven't meaningfully changed
        let snapshotText = best.map { "\($0.appName) \($0.intent) \($0.relatedTopics.joined(separator: " "))" }.joined(separator: " ")
        if !FovealRouter.shouldCallAPI(currentSnapshot: snapshotText, previousEmbedding: &previousFusionEmbedding, driftThreshold: 0.75) {
            return nil
        }

        // Use LLM with calendar-enriched prompt
        let obsData = best.map { (app: $0.appName, intent: $0.intent, topics: $0.relatedTopics) }
        let calendarContext = MeetingIntelligence.calendarContextForSynthesis()
        let prompt = SynthesisPrompts.crossAppFusionPrompt(observations: obsData, meetingContext: calendarContext)

        guard let result = await callLLM(prompt: prompt) else {
            // Fallback without LLM
            return CrossAppInsight(
                id: UUID(), timestamp: Date(),
                type: .crossAppFusion,
                title: "Cross-app activity: \(apps.joined(separator: " + "))",
                summary: "Active across \(apps.count) apps with shared topics: \(topics.prefix(5).joined(separator: ", "))",
                sources: best.map { .init(appName: $0.appName, observationType: $0.category.rawValue, snippet: $0.intent, timestamp: $0.timestamp) },
                connectedApps: apps,
                connectedTopics: topics,
                confidence: 0.6,
                actionability: .informational
            )
        }

        return CrossAppInsight(
            id: UUID(), timestamp: Date(),
            type: .crossAppFusion,
            title: result.title,
            summary: result.summary,
            sources: best.map { .init(appName: $0.appName, observationType: $0.category.rawValue, snippet: $0.intent, timestamp: $0.timestamp) },
            connectedApps: apps,
            connectedTopics: topics,
            confidence: 0.8,
            actionability: CrossAppInsight.Actionability(rawValue: result.actionability) ?? .informational
        )
    }

    // MARK: - Research Aggregation

    private func synthesizeResearch() async -> CrossAppInsight? {
        let trail = await MainActor.run { BrowserTrailStore.shared.currentTrail }
        guard trail.count >= minSourcesForResearch else { return nil }

        let trailURLs = Set(trail.map(\.url))
        if activeInsights.contains(where: {
            $0.type == .researchAggregation &&
            Set($0.sources.map(\.snippet)).isSubset(of: trailURLs)
        }) {
            return nil
        }

        let trailTopics = Set(trail.flatMap { [$0.title.lowercased()] })
        let browserApps: Set<String> = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser"]
        let relatedObs = recentObservations.filter { obs in
            !browserApps.contains(obs.appName) &&
            obs.relatedTopics.contains(where: { trailTopics.contains($0.lowercased()) })
        }

        let trailData = trail.map { (url: $0.url, title: $0.title, summary: $0.summary) }
        let obsData = relatedObs.map { (app: $0.appName, intent: $0.intent) }
        let prompt = SynthesisPrompts.researchAggregationPrompt(trails: trailData, observations: obsData)

        guard let result = await callLLM(prompt: prompt) else { return nil }

        let allApps = Array(Set(["Browser"] + relatedObs.map(\.appName)).sorted())
        let allTopics = Array(Set(trail.map(\.title) + relatedObs.flatMap(\.relatedTopics)).prefix(10))

        return CrossAppInsight(
            id: UUID(), timestamp: Date(),
            type: .researchAggregation,
            title: result.title,
            summary: result.summary,
            sources: trail.map { .init(appName: "Browser", observationType: "browsing", snippet: $0.url, timestamp: $0.timestamp) },
            connectedApps: allApps,
            connectedTopics: allTopics,
            confidence: 0.75,
            actionability: CrossAppInsight.Actionability(rawValue: result.actionability) ?? .informational
        )
    }

    // MARK: - Project Rollup (On-Demand)

    func synthesizeProject(topic: String, daysBack: Int = 7) async -> CrossAppInsight? {
        let journals = JournalStore.shared.recentJournals(limit: 100)
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()

        let topicLower = topic.lowercased()
        let matching = journals.filter { j in
            j.startTime >= cutoff && (
                j.taskDescription.lowercased().contains(topicLower) ||
                j.topicTerms.contains(where: { $0.lowercased().contains(topicLower) }) ||
                j.apps.contains(where: { $0.lowercased().contains(topicLower) })
            )
        }

        guard !matching.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let journalData = matching.map { j in
            (date: formatter.string(from: j.startTime),
             task: j.taskDescription,
             apps: j.apps,
             topics: j.topicTerms)
        }

        let goals = GoalTracker.shared.topGoals(limit: 10)
        let goalName = goals.first(where: {
            $0.topic.lowercased().contains(topicLower) ||
            $0.relatedTopics.contains(where: { $0.lowercased().contains(topicLower) })
        })?.topic

        let prompt = SynthesisPrompts.projectRollupPrompt(journals: journalData, goalName: goalName)
        guard let result = await callLLM(prompt: prompt) else { return nil }

        let allApps = Array(Set(matching.flatMap(\.apps)).sorted())
        let allTopics = Array(Set(matching.flatMap(\.topicTerms)).prefix(10))

        let insight = CrossAppInsight(
            id: UUID(), timestamp: Date(),
            type: .projectRollup,
            title: result.title,
            summary: result.summary,
            sources: matching.map { .init(appName: $0.apps.first ?? "Unknown", observationType: "session", snippet: $0.taskDescription, timestamp: $0.startTime) },
            connectedApps: allApps,
            connectedTopics: allTopics,
            confidence: 0.85,
            actionability: CrossAppInsight.Actionability(rawValue: result.actionability) ?? .informational
        )

        addInsight(insight)
        return insight
    }

    // MARK: - Insight Management

    private func addInsight(_ insight: CrossAppInsight) {
        activeInsights.append(insight)
        insightHistory.append(insight)

        if activeInsights.count > maxActiveInsights {
            activeInsights.removeFirst(activeInsights.count - maxActiveInsights)
        }
        if insightHistory.count > maxHistory {
            insightHistory.removeFirst(insightHistory.count - maxHistory)
        }

        updateCachedPrompt()
        print("[CrossAppSynthesizer] New insight: \(insight.title) (\(insight.type.rawValue), confidence: \(String(format: "%.2f", insight.confidence)))")
    }

    private func expireOldInsights() {
        let cutoff = Date().addingTimeInterval(-insightTTL)
        activeInsights.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Public Accessors

    /// Returns active insights formatted for LLM prompt injection.
    func activeInsightsForPrompt() -> String {
        expireOldInsights()
        return Self.formatInsightsForPrompt(activeInsights)
    }

    /// Returns all active insights (for tool responses).
    func getActiveInsights() -> [CrossAppInsight] {
        expireOldInsights()
        return activeInsights
    }

    /// Returns insight history (for tool responses).
    func getInsightHistory(limit: Int = 20) -> [CrossAppInsight] {
        Array(insightHistory.suffix(limit))
    }

    /// Force a synthesis pass (for on-demand tool calls).
    func forceSynthesis() async {
        hasNewData = true
        await runSynthesisPass()
    }

    // MARK: - Cached Prompt (synchronous access for LearningContextProvider)

    private static let _cachedPrompt = NSLock()
    private static var _cachedPromptValue: String = ""

    /// Synchronous accessor — no await needed.
    nonisolated static var cachedPromptSection: String {
        _cachedPrompt.lock()
        defer { _cachedPrompt.unlock() }
        return _cachedPromptValue
    }

    private func updateCachedPrompt() {
        let value = Self.formatInsightsForPrompt(activeInsights)
        Self._cachedPrompt.lock()
        Self._cachedPromptValue = value
        Self._cachedPrompt.unlock()
    }

    private static func formatInsightsForPrompt(_ insights: [CrossAppInsight]) -> String {
        guard !insights.isEmpty else { return "" }
        var lines = ["## Active Cross-App Intelligence:"]
        for insight in insights.suffix(5) {
            lines.append("- \(insight.promptLine)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - LLM Helper

    private struct LLMResult {
        let title: String
        let summary: String
        let actionability: String
    }

    private nonisolated func callLLM(prompt: String) async -> LLMResult? {
        do {
            let messages = [
                ChatMessage(role: "system", content: "You are a synthesis engine that connects observations across apps. Respond ONLY with a JSON object containing title, summary, and actionability fields. No markdown fences."),
                ChatMessage(role: "user", content: prompt),
            ]
            let service = LLMServiceManager.shared.currentService
            let response = try await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 300)
            guard let responseText = response.text else { return nil }

            let text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String,
                  let summary = json["summary"] as? String else {
                // Try extracting JSON from markdown fences
                if let range = text.range(of: "\\{[^}]+\\}", options: .regularExpression),
                   let data2 = String(text[range]).data(using: .utf8),
                   let json2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
                   let t = json2["title"] as? String,
                   let s = json2["summary"] as? String {
                    return LLMResult(title: t, summary: s, actionability: json2["actionability"] as? String ?? "informational")
                }
                return nil
            }

            return LLMResult(
                title: title,
                summary: summary,
                actionability: json["actionability"] as? String ?? "informational"
            )
        } catch {
            print("[CrossAppSynthesizer] LLM call failed: \(error.localizedDescription)")
            return nil
        }
    }
}
