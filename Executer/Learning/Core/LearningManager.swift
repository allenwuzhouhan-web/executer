import Foundation
import AppKit

/// Orchestrates all learning: observes user actions, extracts patterns,
/// and provides LLM-injectable context.
/// Phase 0 refactoring: delegates storage to LearningDatabase (SQLite),
/// pattern extraction to PatternLearner, and keeps only orchestration logic.
/// Phase 1 (Workflow Recorder): Replaced callback-based observation with
/// ContinuousPerceptionDaemon + ObservationStream for always-on unified perception.
class LearningManager {
    static let shared = LearningManager()

    private var actionBuffer: ContiguousArray<UserAction> = []
    private let bufferLock = NSLock()
    private var flushTimer: Timer?
    private var screenSampleTimer: Timer?
    private var lastExtraction: Date = .distantPast

    /// Whether the new ObservationStream pipeline is active.
    private var daemonStarted = false

    var isEnabled: Bool {
        get { LearningConfig.shared.isLearningEnabled }
        set { LearningConfig.shared.isLearningEnabled = newValue }
    }

    private init() {
        // Run one-time migration from JSON to SQLite
        LearningMigration.migrateIfNeeded()
        // Prune old observations
        LearningDatabase.shared.pruneObservations(olderThanDays: LearningConstants.observationRetentionDays)
    }

    // MARK: - Start / Stop

    func start() {
        guard isEnabled else { return }

        // Start the unified observation pipeline (Phase 1: Workflow Recorder)
        startObservationPipeline()

        // Periodic flush timer (for buffered actions → SQLite + pattern extraction)
        flushTimer = Timer.scheduledTimer(withTimeInterval: LearningConstants.bufferFlushInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }

        // Start summary scheduler
        SummaryScheduler.shared.start()

        // Start smart app launch detection
        SmartLaunchDetector.shared.start()

        // Set adaptive sampling rate based on learning maturity
        AdaptiveSampling.shared.recalculateInterval()

        print("[Learning] Started — always-on observation pipeline active")

        // Show one-time onboarding message
        LearningOnboarding.showIfNeeded()

        // Show subtle learning indicator
        DispatchQueue.main.async {
            LearningGlowWindow.shared.show()
        }

        NotificationCenter.default.post(name: .learningStateChanged, object: nil, userInfo: ["isLearning": true])
    }

    /// Start the ContinuousPerceptionDaemon and register consumers.
    /// Replaces the old callback-based wiring (AppObserver.onAction, FileMonitor.onFileEvent, etc.)
    /// with a unified stream that all consumers subscribe to.
    private func startObservationPipeline() {
        guard !daemonStarted else { return }
        daemonStarted = true

        Task(priority: .utility) {
            let daemon = ContinuousPerceptionDaemon.shared

            // Consumer 1: Action recording (TeachMe + buffer for SQLite/patterns)
            await daemon.addConsumer(name: "actionRecorder") { [weak self] event in
                if case .userAction(let action) = event {
                    self?.recordAction(action)
                }
            }

            // Consumer 2: Semantic observation routing (AttentionTracker + SessionDetector)
            await daemon.addConsumer(name: "semanticRouter") { event in
                switch event {
                case .userAction(let action):
                    let observations = AttentionRouter.route(actions: [action], appName: action.appName)
                    if !observations.isEmpty {
                        AttentionTracker.shared.record(observations)
                        SessionDetector.shared.ingest(observations)
                    }

                case .fileEvent(let fileEvent):
                    let obs = SemanticObservation(
                        appName: fileEvent.appName,
                        category: .other,
                        intent: "File \(fileEvent.eventType.rawValue) in \(fileEvent.directory) (\(fileEvent.fileExtension))",
                        details: ["directory": fileEvent.directory, "extension": fileEvent.fileExtension, "event": fileEvent.eventType.rawValue],
                        relatedTopics: [fileEvent.directory, fileEvent.fileExtension]
                    )
                    AttentionTracker.shared.record([obs])
                    SessionDetector.shared.ingest([obs])

                case .clipboardFlow(let flow):
                    let obs = SemanticObservation(
                        appName: flow.sourceApp,
                        category: .other,
                        intent: "Clipboard: \(flow.sourceApp) → \(flow.destinationApp) (\(flow.contentType.rawValue), \(flow.contentLength) chars)",
                        details: ["source": flow.sourceApp, "destination": flow.destinationApp, "type": flow.contentType.rawValue],
                        relatedTopics: [flow.sourceApp, flow.destinationApp]
                    )
                    AttentionTracker.shared.record([obs])
                    SessionDetector.shared.ingest([obs])

                case .screenSample(let sample):
                    let observations = AttentionRouter.route(actions: [], appName: sample.appName, screenText: sample.visibleTextPreview)
                    if !observations.isEmpty {
                        AttentionTracker.shared.record(observations)
                        SessionDetector.shared.ingest(observations)
                    }

                case .systemEvent(let sysEvent):
                    switch sysEvent.kind {
                    case .screenLocked:
                        await ContinuousPerceptionDaemon.shared.handleScreenLock()
                    case .screenUnlocked:
                        await ContinuousPerceptionDaemon.shared.handleScreenUnlock()
                    default:
                        break
                    }
                case .oeAppEvent, .oeURLEvent, .oeActivityEvent, .oeTransitionEvent, .oeFileEvent:
                    break
                }
            }

            // Consumer 3: Goal tracking (process completed sessions)
            await daemon.addConsumer(name: "goalTracker") { _ in
                // Use todaysSessions() which acquires NSLock (thread-safe)
                for session in SessionDetector.shared.todaysSessions().filter({ !$0.isActive }) {
                    GoalTracker.shared.processSession(session)
                }
            }

            // Consumer 4: Journal recording (Phase 3 — registered BEFORE boundary detector
            // so the journal is ready to receive events before boundaries trigger new journals)
            await daemon.addConsumer(name: "journalRecorder") { event in
                await JournalManager.shared.recordEvent(event)
            }

            // Consumer 5: Task boundary detection (Phase 2: Workflow Recorder)
            await TaskBoundaryDetector.shared.applyCalibration()
            await TaskBoundaryDetector.shared.setOnBoundary { boundary in
                Task { await JournalManager.shared.handleBoundary(boundary) }
            }
            await daemon.addConsumer(name: "boundaryDetector") { event in
                await TaskBoundaryDetector.shared.process(event)
            }

            // Consumer 6: Autonomous workflow agent (Phase 20: The Sovereign)
            await AutonomousWorkflowAgent.shared.start()
            await daemon.addConsumer(name: "autonomousAgent") { event in
                await AutonomousWorkflowAgent.shared.processEvent(event)
            }

            // Start journal archiver (30-day archive, 90-day purge)
            JournalArchiver.shared.start()

            // Start the daemon (wires ObservationStream → Throttler → Consumers)
            await daemon.start()
        }
    }

    func stop() {
        // Stop the unified observation pipeline
        if daemonStarted {
            daemonStarted = false
            Task {
                await AutonomousWorkflowAgent.shared.stop()
                await JournalManager.shared.shutdown()
                await ContinuousPerceptionDaemon.shared.stop()
            }
            JournalArchiver.shared.stop()
        }

        // Hide learning indicator
        DispatchQueue.main.async {
            LearningGlowWindow.shared.hide()
        }

        NotificationCenter.default.post(name: .learningStateChanged, object: nil, userInfo: ["isLearning": false])
        SmartLaunchDetector.shared.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        SummaryScheduler.shared.stop()
        screenSampleTimer?.invalidate()
        screenSampleTimer = nil
        flushBuffer()
        // Encrypt database at rest
        LearningDatabase.shared.encryptAtRest()
        print("[Learning] Stopped")
    }

    // MARK: - Action Recording

    private func recordAction(_ action: UserAction) {
        bufferLock.lock()
        actionBuffer.append(action)
        // Feed to TeachMe mode if active
        TeachMeMode.shared.recordAction(action)
        let shouldFlush = actionBuffer.count >= LearningConstants.bufferFlushThreshold
        bufferLock.unlock()

        if shouldFlush {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        bufferLock.lock()
        guard !actionBuffer.isEmpty else {
            bufferLock.unlock()
            return
        }
        let actions = Array(actionBuffer)
        actionBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        // Batch insert into SQLite
        LearningDatabase.shared.insertObservations(actions)

        // Periodically extract patterns
        if Date().timeIntervalSince(lastExtraction) > LearningConstants.patternExtractionInterval {
            extractPatterns(forActions: actions)
            lastExtraction = Date()
        }
    }

    // MARK: - Pattern Extraction

    private func extractPatterns(forActions actions: [UserAction]) {
        // Group by app and extract patterns
        let appNames = Set(actions.map(\.appName))
        for appName in appNames {
            let recentActions = LearningDatabase.shared.recentObservations(forApp: appName, limit: LearningConstants.maxRecentObservations)
            let existingPatterns = LearningDatabase.shared.topPatterns(forApp: appName, limit: LearningConstants.maxPatternsPerApp)

            // Build a temporary profile for PatternLearner (it still uses the old interface)
            var profile = AppLearningProfile(
                appName: appName,
                recentActions: recentActions,
                patterns: existingPatterns,
                totalActionsObserved: recentActions.count,
                lastUpdated: Date()
            )

            PatternLearner.shared.extractPatterns(from: &profile)

            // Save updated patterns back to SQLite
            LearningDatabase.shared.replacePatterns(forApp: appName, patterns: profile.patterns)

            // Auto-compile high-confidence patterns into skills
            autoCompilePatterns(profile.patterns, appName: appName)
        }
        print("[Learning] Extracted patterns for \(appNames.count) apps")

        // Trigger learning feedback loop: convert high-frequency patterns to rules
        Task { await LearningFeedbackLoop.generateRules() }
    }

    // MARK: - Auto-Compile Patterns → Skills

    /// Patterns observed 5+ times get compiled into executable skills.
    /// Skills are iterative — if the pattern changes, the skill updates.
    private var compiledPatternIds: Set<UUID> = []

    private func autoCompilePatterns(_ patterns: [WorkflowPattern], appName: String) {
        let eligible = patterns.filter { $0.frequency >= 5 && $0.actions.count >= 3 }
        guard !eligible.isEmpty else { return }
        Task { await WorkflowCompressionBridge.shared.enqueue(eligible) }
    }

    // MARK: - LLM Context Injection

    /// Returns learned patterns for the specified app, formatted for LLM prompt injection.
    func promptSection(forApp appName: String) -> String {
        let patterns = LearningDatabase.shared.topPatterns(forApp: appName, limit: LearningConstants.maxPatternsInPrompt)
        guard !patterns.isEmpty else { return "" }

        var lines = ["## Learned Patterns for \(appName) (from observing the user):"]
        for pattern in patterns {
            lines.append("### \(pattern.name) (observed \(pattern.frequency)x)")
            for (i, action) in pattern.actions.enumerated() {
                var step = "  \(i + 1). \(action.type.rawValue)"
                if !action.elementTitle.isEmpty { step += " → \"\(action.elementTitle)\"" }
                if !action.elementRole.isEmpty { step += " [\(action.elementRole)]" }
                if !action.elementValue.isEmpty { step += " = \"\(action.elementValue.prefix(80))\"" }
                lines.append(step)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns learned patterns for the frontmost app.
    func promptSectionForFrontmostApp() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return "" }
        return promptSection(forApp: name)
    }

    /// Returns a summary of all learned apps and their pattern counts.
    func overallSummary() -> String {
        let apps = LearningDatabase.shared.allAppNames()
        guard !apps.isEmpty else { return "No app patterns learned yet." }

        var lines = ["Learned app patterns:"]
        for (name, patternCount, obsCount) in apps {
            lines.append("  \(name): \(patternCount) patterns, \(obsCount) actions observed")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns a full UI tree reading of the frontmost app (on-demand, not cached).
    func readCurrentScreen() -> String? {
        return ScreenReader.summarizeFrontmostApp()
    }

    // MARK: - Data Management

    /// Clears all learned data for a specific app.
    func clearApp(_ appName: String) {
        LearningDatabase.shared.deleteApp(appName)
    }

    /// Clears all learned data.
    func clearAll() {
        LearningDatabase.shared.deleteAllData()
    }

    /// List of all apps with learned profiles.
    var learnedApps: [(name: String, patternCount: Int, actionCount: Int)] {
        LearningDatabase.shared.allAppNames().map { ($0.name, $0.patternCount, $0.observationCount) }
    }
}

extension Notification.Name {
    static let learningStateChanged = Notification.Name("com.executer.learningStateChanged")
}
