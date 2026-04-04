import Foundation
import AppKit

/// Orchestrates all learning: observes user actions, extracts patterns,
/// and provides LLM-injectable context.
/// Phase 0 refactoring: delegates storage to LearningDatabase (SQLite),
/// pattern extraction to PatternLearner, and keeps only orchestration logic.
class LearningManager {
    static let shared = LearningManager()

    private var actionBuffer: ContiguousArray<UserAction> = []
    private let bufferLock = NSLock()
    private var flushTimer: Timer?
    private var screenSampleTimer: Timer?
    private var lastExtraction: Date = .distantPast

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

        AppObserver.shared.onAction = { [weak self] action in
            self?.recordAction(action)
        }
        AppObserver.shared.start()

        // Periodic flush timer
        flushTimer = Timer.scheduledTimer(withTimeInterval: LearningConstants.bufferFlushInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }

        // Start summary scheduler
        SummaryScheduler.shared.start()

        // Start file and clipboard monitors
        FileMonitor.shared.onFileEvent = { [weak self] event in
            // Convert file events to semantic observations
            let obs = SemanticObservation(
                appName: event.appName,
                category: .other,
                intent: "File \(event.eventType.rawValue) in \(event.directory) (\(event.fileExtension))",
                details: ["directory": event.directory, "extension": event.fileExtension, "event": event.eventType.rawValue],
                relatedTopics: [event.directory, event.fileExtension]
            )
            AttentionTracker.shared.record([obs])
            SessionDetector.shared.ingest([obs])
        }
        FileMonitor.shared.start()

        ClipboardObserver.shared.onClipboardFlow = { flow in
            let obs = SemanticObservation(
                appName: flow.sourceApp,
                category: .other,
                intent: "Clipboard: \(flow.sourceApp) → \(flow.destinationApp) (\(flow.contentType.rawValue), \(flow.contentLength) chars)",
                details: ["source": flow.sourceApp, "destination": flow.destinationApp, "type": flow.contentType.rawValue],
                relatedTopics: [flow.sourceApp, flow.destinationApp]
            )
            AttentionTracker.shared.record([obs])
            SessionDetector.shared.ingest([obs])
        }
        ClipboardObserver.shared.start()

        // Start smart app launch detection
        SmartLaunchDetector.shared.start()

        // Set adaptive sampling rate based on learning maturity
        AdaptiveSampling.shared.recalculateInterval()

        // Adaptive screen sampling — interval changes based on learning age and active app
        if LearningConfig.shared.isScreenSamplingEnabled {
            startAdaptiveScreenSampling()
        }

        print("[Learning] Started — observing user workflows")

        // Show one-time onboarding message
        LearningOnboarding.showIfNeeded()

        // Show subtle learning indicator
        DispatchQueue.main.async {
            LearningGlowWindow.shared.show()
        }

        NotificationCenter.default.post(name: .learningStateChanged, object: nil, userInfo: ["isLearning": true])
    }

    func stop() {
        AppObserver.shared.stop()

        // Hide learning indicator
        DispatchQueue.main.async {
            LearningGlowWindow.shared.hide()
        }

        NotificationCenter.default.post(name: .learningStateChanged, object: nil, userInfo: ["isLearning": false])
        SmartLaunchDetector.shared.stop()
        FileMonitor.shared.stop()
        ClipboardObserver.shared.stop()
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

        // Phase 2: Route through attention extractors
        let groupedByApp = Dictionary(grouping: actions, by: \.appName)
        for (appName, appActions) in groupedByApp {
            let observations = AttentionRouter.route(actions: appActions, appName: appName)
            if !observations.isEmpty {
                AttentionTracker.shared.record(observations)
                SessionDetector.shared.ingest(observations)
            }
        }

        // Phase 3: Process completed sessions through GoalTracker
        for session in SessionDetector.shared.completedSessions {
            GoalTracker.shared.processSession(session)
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
        for pattern in patterns {
            // Only compile patterns with enough confidence (5+ observations)
            guard pattern.frequency >= 5 else { continue }
            // Only compile patterns with 3+ steps (trivial patterns aren't useful as skills)
            guard pattern.actions.count >= 3 else { continue }

            // Check if this pattern already has a compiled skill
            let skillName = "auto_\(appName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(pattern.name.lowercased().prefix(30).replacingOccurrences(of: " ", with: "_"))"

            // Compile pattern into a workflow template
            guard let template = WorkflowCompiler.compile(pattern) else { continue }

            // Check if skill already exists — if so, UPDATE it (patterns evolve)
            let existingSkill = SkillsManager.shared.skills.first { $0.name == skillName }
            let steps = template.steps.map { $0.description }

            let skill = SkillsManager.Skill(
                name: skillName,
                description: "Auto-learned: \(pattern.name) (observed \(pattern.frequency)x)",
                exampleTriggers: [pattern.name.lowercased(), "\(appName.lowercased()) \(pattern.name.lowercased())"],
                steps: steps,
                verificationStatus: "verified"  // Auto-compiled from observation — safe
            )

            if existingSkill != nil {
                // Skill exists — update it if the pattern has evolved
                if existingSkill?.steps != steps {
                    SkillsManager.shared.addSkill(skill)
                    print("[Learning] Updated auto-skill: \(skillName) (\(pattern.frequency)x, \(steps.count) steps)")
                }
            } else {
                // New skill — compile and save
                SkillsManager.shared.addSkill(skill)
                TemplateLibrary.shared.save(template)
                print("[Learning] Auto-compiled skill: \(skillName) (\(pattern.frequency)x, \(steps.count) steps)")
            }
        }
    }

    // MARK: - Adaptive Screen Sampling

    private func startAdaptiveScreenSampling() {
        screenSampleTimer?.invalidate()

        let interval = AdaptiveSampling.shared.currentInterval
        screenSampleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleScreen()

            // Check if interval should change (app boost, time progression)
            let newInterval = AdaptiveSampling.shared.currentInterval
            if abs(newInterval - interval) > 1.0 {
                // Interval changed — restart timer with new interval
                self?.startAdaptiveScreenSampling()
            }
        }

        print("[Learning] Screen sampling at \(Int(interval))s intervals")
    }

    // MARK: - Screen Sampling

    private func sampleScreen() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName,
              app.bundleIdentifier != "com.allenwu.executer" else { return }

        let texts = ScreenReader.readVisibleText(pid: app.processIdentifier)
        guard !texts.isEmpty else { return }

        // Route screen text through attention extractors (text is transient, never stored)
        let observations = AttentionRouter.route(actions: [], appName: name, screenText: texts)
        if !observations.isEmpty {
            AttentionTracker.shared.record(observations)
            SessionDetector.shared.ingest(observations)
        }
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
