import Foundation

/// Detects when one logical task ends and another begins by fusing five
/// independent signals into a weighted confidence score.
///
/// This is Phase 2 of the Workflow Recorder ("The Boundary Oracle").
/// Much finer-grained than SessionDetector (which uses 30-min gaps + Jaccard).
/// TaskBoundaryDetector operates in real-time on individual ObservationEvents
/// and detects boundaries within seconds, not minutes.
///
/// Signal Fusion:
///   1. App switch pattern   — single decisive switch after sustained activity
///   2. Document change      — new window title, Cmd+N detected, file open
///   3. Topic drift          — embedding distance from running centroid > threshold
///   4. Temporal gap         — no events for N seconds
///   5. System events        — screen unlock (likely new task), app quit
///
/// Each signal contributes a weighted score [0, 1]. When the sum exceeds
/// `boundaryThreshold`, a TaskBoundary is emitted.
actor TaskBoundaryDetector {
    static let shared = TaskBoundaryDetector()

    // MARK: - Configuration

    /// Combined score threshold to trigger a boundary.
    /// Range 0–5 (sum of all signal weights). Default 0.55 — roughly one strong signal
    /// or two moderate signals needed.
    private var boundaryThreshold: Double = 0.55

    /// Minimum task duration before a new boundary can fire.
    /// Prevents micro-tasks from being created during rapid app exploration.
    private let minimumTaskDuration: TimeInterval = 15  // 15 seconds

    /// Temporal gap threshold for gap-based boundaries (much shorter than SessionDetector's 30min).
    private let temporalGapThreshold: TimeInterval = 180  // 3 minutes (catches coffee/bathroom breaks)

    /// Cooldown after emitting a boundary — adaptive per boundary kind.
    private let hardBoundaryCooldown: TimeInterval = 2     // Explicit actions (menu "New", app quit)
    private let softBoundaryCooldown: TimeInterval = 10    // Gradual topic drift
    private let temporalBoundaryCooldown: TimeInterval = 5 // Inactivity gap

    // MARK: - Signal Weights (sum to ~1.0 by default, calibrator adjusts)

    private var signalWeights: [BoundarySignal: Double] = [
        .appSwitchPattern: 0.25,
        .documentChange: 0.30,
        .topicDrift: 0.25,
        .temporalGap: 0.35,
        .systemEvent: 0.40,
    ]

    // MARK: - State

    /// Current task context — tracks the active task.
    private(set) var currentTask: TaskContext?

    /// Time and kind of last emitted boundary (for adaptive cooldown).
    private var lastBoundaryTime: Date = .distantPast
    private var lastBoundaryKind: TaskBoundary.Kind = .soft

    /// Recent app switch history for velocity analysis.
    private var recentAppSwitches: [(app: String, time: Date)] = []

    /// The topic drift monitor.
    private let driftMonitor = TopicDriftMonitor()

    /// Boundary calibrator — adjusts weights from user feedback.
    private let calibrator = BoundaryCalibrator()

    /// Callback for emitting boundaries (set by the daemon wiring).
    private var onBoundary: ((TaskBoundary) -> Void)?

    // MARK: - Setup

    /// Set the callback for boundary events.
    func setOnBoundary(_ handler: @escaping (TaskBoundary) -> Void) {
        self.onBoundary = handler
    }

    /// Apply calibrated weights from BoundaryCalibrator.
    func applyCalibration() async {
        let calibratedWeights = await calibrator.currentWeights()
        if !calibratedWeights.isEmpty {
            signalWeights = calibratedWeights
            print("[BoundaryDetector] Applied calibrated weights: \(signalWeights.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: ", "))")
        }
        let calibratedThreshold = await calibrator.currentThreshold()
        if calibratedThreshold > 0 {
            boundaryThreshold = calibratedThreshold
        }
    }

    // MARK: - Event Processing

    /// Process a single observation event from the ObservationStream.
    /// Evaluates all signals and emits a boundary if the threshold is exceeded.
    func process(_ event: ObservationEvent) {
        // Initialize first task if needed
        if currentTask == nil {
            if let app = event.appName {
                currentTask = TaskContext(firstApp: app, startTime: event.timestamp)
                print("[BoundaryDetector] Initial task started in \(app)")
            }
            return
        }

        guard var task = currentTask else { return }

        // Check cooldown
        // Adaptive cooldown based on last boundary kind
        let cooldown: TimeInterval
        switch lastBoundaryKind {
        case .hard: cooldown = hardBoundaryCooldown
        case .soft: cooldown = softBoundaryCooldown
        case .temporal: cooldown = temporalBoundaryCooldown
        }
        guard Date().timeIntervalSince(lastBoundaryTime) > cooldown else {
            updateTaskContext(&task, with: event)
            currentTask = task
            return
        }

        // Evaluate all signals
        var signals: [TaskBoundary.SignalContribution] = []
        var totalScore: Double = 0
        var triggerEvent: TaskBoundary.TriggerEvent?
        var boundaryKind: TaskBoundary.Kind = .soft

        // Signal 1: App switch pattern
        if let appSignal = evaluateAppSwitch(event: event, task: task) {
            signals.append(appSignal)
            totalScore += appSignal.weight
            if appSignal.weight > 0.2, case .userAction(let action) = event {
                triggerEvent = .appSwitch(from: task.primaryApp, to: action.appName)
            }
        }

        // Signal 2: Document/window change
        if let docSignal = evaluateDocumentChange(event: event, task: task) {
            signals.append(docSignal)
            totalScore += docSignal.weight
            if docSignal.weight > 0.2 {
                boundaryKind = .hard
                let windowTitle = extractWindowTitle(from: event) ?? "unknown"
                triggerEvent = triggerEvent ?? .documentChange(app: event.appName ?? "Unknown", windowTitle: windowTitle)
            }
        }

        // Signal 3: Topic drift
        if let driftSignal = evaluateTopicDrift(event: event, task: task) {
            signals.append(driftSignal)
            totalScore += driftSignal.weight
            if driftSignal.weight > 0.2 {
                triggerEvent = triggerEvent ?? .topicDrift(distance: driftSignal.rawValue)
            }
        }

        // Signal 4: Temporal gap
        if let gapSignal = evaluateTemporalGap(event: event, task: task) {
            signals.append(gapSignal)
            totalScore += gapSignal.weight
            if gapSignal.weight > 0.2 {
                boundaryKind = .temporal
                triggerEvent = triggerEvent ?? .temporalGap(seconds: gapSignal.rawValue)
            }
        }

        // Signal 5: System events
        if let sysSignal = evaluateSystemEvent(event: event, task: task) {
            signals.append(sysSignal)
            totalScore += sysSignal.weight
            if sysSignal.weight > 0.2 {
                boundaryKind = .hard
                triggerEvent = triggerEvent ?? .systemEvent(kind: "system")
            }
        }

        // Check if boundary threshold is exceeded
        let taskOldEnough = task.duration >= minimumTaskDuration
        if totalScore >= boundaryThreshold && taskOldEnough {
            let boundary = TaskBoundary(
                kind: boundaryKind,
                confidence: min(totalScore / signalWeights.values.reduce(0, +), 1.0),
                trigger: triggerEvent ?? .temporalGap(seconds: 0),
                signals: signals
            )
            emitBoundary(boundary, startingApp: event.appName)
        } else {
            // No boundary — update the current task context
            updateTaskContext(&task, with: event)
            currentTask = task
        }
    }

    // MARK: - Signal Evaluators

    /// Signal 1: App switch pattern analysis.
    /// A single decisive app switch after sustained activity in one app is a strong boundary signal.
    /// Rapid oscillation between apps (alt-tabbing) is NOT a boundary.
    private func evaluateAppSwitch(event: ObservationEvent, task: TaskContext) -> TaskBoundary.SignalContribution? {
        guard let newApp = event.appName, newApp != task.primaryApp else { return nil }

        // Record the switch
        recentAppSwitches.append((app: newApp, time: event.timestamp))

        // Keep only last 60 seconds of switches
        let cutoff = event.timestamp.addingTimeInterval(-60)
        recentAppSwitches.removeAll { $0.time < cutoff }

        // Calculate switch velocity (switches per minute)
        let switchCount = recentAppSwitches.count
        let velocity = Double(switchCount) // Already in 60s window

        // High velocity (>4 switches/min) = exploration, not a boundary
        // Low velocity (1-2 switches after sustained work) = likely boundary
        let rawValue: Double
        if velocity <= 2 && task.duration > 30 {
            // Decisive switch after sustained work
            rawValue = 0.9
        } else if velocity <= 3 && task.duration > 60 {
            rawValue = 0.6
        } else if velocity > 5 {
            // Rapid switching — suppress boundary
            rawValue = 0.0
        } else {
            rawValue = 0.3
        }

        let weight = signalWeights[.appSwitchPattern, default: 0.25]
        return TaskBoundary.SignalContribution(
            signal: BoundarySignal.appSwitchPattern,
            weight: rawValue * weight,
            rawValue: rawValue
        )
    }

    /// Signal 2: Document/window change detection.
    /// New window titles, windowOpen events, and menu selections of "New" / "Open" are strong signals.
    private func evaluateDocumentChange(event: ObservationEvent, task: TaskContext) -> TaskBoundary.SignalContribution? {
        guard case .userAction(let action) = event else { return nil }

        var rawValue: Double = 0

        switch action.type {
        case .windowOpen:
            // New window = strong signal for new task
            rawValue = 0.8
        case .menuSelect:
            // "New", "Open", "New Document", etc.
            let title = action.elementTitle.lowercased()
            if title.contains("new") || title.contains("open") || title.contains("import") {
                rawValue = 0.9
            }
        case .focus, .click:
            // Check if window title changed significantly
            let newTitle = action.elementTitle
            if !newTitle.isEmpty, let lastTitle = task.lastWindowTitle, !lastTitle.isEmpty {
                let similarity = TextEmbedder.textSimilarity(newTitle, lastTitle)
                if similarity < 0.3 {
                    // Very different window title
                    rawValue = 0.6
                }
            }
        default:
            break
        }

        guard rawValue > 0 else { return nil }

        let weight = signalWeights[.documentChange, default: 0.30]
        return TaskBoundary.SignalContribution(
            signal: BoundarySignal.documentChange,
            weight: rawValue * weight,
            rawValue: rawValue
        )
    }

    /// Signal 3: Topic drift via embedding centroid.
    /// Measures cosine distance between new observation's topics and the task's running centroid.
    private func evaluateTopicDrift(event: ObservationEvent, task: TaskContext) -> TaskBoundary.SignalContribution? {
        // Extract semantic text from the event
        let text = extractSemanticText(from: event)
        guard !text.isEmpty else { return nil }

        let result = driftMonitor.checkDrift(text: text, context: task)
        guard result.distance > 0.1 else { return nil }  // Ignore negligible drift

        // Scale: distance 0.4 = low (0.3 raw), 0.6 = medium (0.7 raw), 0.8+ = high (1.0 raw)
        let rawValue: Double
        if result.distance > 0.8 {
            rawValue = 1.0
        } else if result.distance > 0.6 {
            rawValue = 0.7
        } else if result.distance > 0.4 {
            rawValue = 0.3
        } else {
            rawValue = 0.1
        }

        let weight = signalWeights[.topicDrift, default: 0.25]
        return TaskBoundary.SignalContribution(
            signal: BoundarySignal.topicDrift,
            weight: rawValue * weight,
            rawValue: result.distance
        )
    }

    /// Signal 4: Temporal gap.
    /// If no events have been received for a while, likely a task boundary.
    private func evaluateTemporalGap(event: ObservationEvent, task: TaskContext) -> TaskBoundary.SignalContribution? {
        let gap = event.timestamp.timeIntervalSince(task.lastEventTime)
        guard gap > 30 else { return nil }  // Ignore sub-30s gaps

        // Scale: 30s = weak, 2min = moderate, 5min+ = strong
        let rawValue: Double
        if gap >= temporalGapThreshold {
            rawValue = 1.0
        } else if gap >= 120 {
            rawValue = 0.7
        } else if gap >= 60 {
            rawValue = 0.4
        } else {
            rawValue = 0.2
        }

        let weight = signalWeights[.temporalGap, default: 0.35]
        return TaskBoundary.SignalContribution(
            signal: BoundarySignal.temporalGap,
            weight: rawValue * weight,
            rawValue: gap
        )
    }

    /// Signal 5: System events.
    /// Screen unlock, app quit, display change — these are strong boundary candidates.
    private func evaluateSystemEvent(event: ObservationEvent, task: TaskContext) -> TaskBoundary.SignalContribution? {
        guard case .systemEvent(let sysEvent) = event else { return nil }

        let rawValue: Double
        switch sysEvent.kind {
        case .screenUnlocked:
            // Coming back from lock — very likely new task
            rawValue = 0.9
        case .appQuit(let name) where name == task.primaryApp:
            // Primary app quit — definite boundary
            rawValue = 1.0
        case .appQuit:
            // Some other app quit — mild signal
            rawValue = 0.2
        case .displayCountChanged:
            // Monitor change (docking/undocking) — moderate signal
            rawValue = 0.5
        case .wifiChanged:
            // Location change — moderate signal
            rawValue = 0.4
        case .focusModeChanged(let mode):
            // Focus mode change — DND/Sleep = strong, Work = mild
            let modeLower = mode.lowercased()
            if modeLower.contains("sleep") || modeLower.contains("not disturb") || modeLower == "dnd" {
                rawValue = 0.8
            } else if modeLower.contains("work") {
                rawValue = 0.3
            } else {
                rawValue = 0.2
            }
        case .powerSourceChanged:
            rawValue = 0.2
        default:
            return nil
        }

        let weight = signalWeights[.systemEvent, default: 0.40]
        return TaskBoundary.SignalContribution(
            signal: BoundarySignal.systemEvent,
            weight: rawValue * weight,
            rawValue: rawValue
        )
    }

    // MARK: - Helpers

    /// Emit a boundary and start a new task.
    private func emitBoundary(_ boundary: TaskBoundary, startingApp: String?) {
        lastBoundaryTime = Date()
        lastBoundaryKind = boundary.kind

        let oldTask = currentTask
        // Start new task
        currentTask = TaskContext(firstApp: startingApp ?? "Unknown")
        recentAppSwitches.removeAll()

        print("[BoundaryDetector] Boundary detected: \(boundary.kind.rawValue) (confidence: \(String(format: "%.2f", boundary.confidence)), signals: \(boundary.signals.map { "\($0.signal.rawValue)=\(String(format: "%.2f", $0.weight))" }.joined(separator: ", ")))")

        // Record for calibration
        Task {
            await calibrator.recordBoundary(boundary, previousTaskDuration: oldTask?.duration ?? 0)
        }

        // Notify listeners
        onBoundary?(boundary)
        NotificationCenter.default.post(
            name: .taskBoundaryDetected,
            object: nil,
            userInfo: ["boundary": boundary]
        )
    }

    /// Update the current task context with a new event.
    private func updateTaskContext(_ task: inout TaskContext, with event: ObservationEvent) {
        task.lastEventTime = event.timestamp
        task.observationCount += 1

        if let newApp = event.appName, !task.apps.contains(newApp) {
            task.apps.append(newApp)
            task.appSwitchCount += 1
        }

        // Update topic centroid
        let text = extractSemanticText(from: event)
        if !text.isEmpty, let vector = TextEmbedder.sentenceVector(text) {
            task.updateCentroid(with: vector)
        }

        // Update topic terms
        let terms = extractTopicTerms(from: event)
        task.topicTerms.formUnion(terms)

        // Track window title
        if let title = extractWindowTitle(from: event), !title.isEmpty {
            task.lastWindowTitle = title
        }
    }

    /// Extract semantic text from an event for embedding.
    private func extractSemanticText(from event: ObservationEvent) -> String {
        switch event {
        case .userAction(let action):
            return [action.appName, action.elementRole, action.elementTitle]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .fileEvent(let e):
            return "file \(e.eventType.rawValue) \(e.directory) \(e.fileExtension)"
        case .clipboardFlow(let f):
            return "clipboard \(f.sourceApp) \(f.destinationApp) \(f.contentType.rawValue)"
        case .screenSample(let s):
            return s.visibleTextPreview.prefix(5).joined(separator: " ")
        case .systemEvent(let s):
            switch s.kind {
            case .appLaunched(let name): return "launched \(name)"
            case .appQuit(let name): return "quit \(name)"
            default: return ""
            }
        }
    }

    /// Extract topic terms from an event.
    private func extractTopicTerms(from event: ObservationEvent) -> [String] {
        switch event {
        case .userAction(let action):
            return [action.appName, action.elementTitle].filter { !$0.isEmpty }
        case .fileEvent(let e):
            return [e.directory, e.fileExtension]
        case .clipboardFlow(let f):
            return [f.sourceApp, f.destinationApp]
        case .screenSample(let s):
            return Array(s.visibleTextPreview.prefix(3))
        case .systemEvent:
            return []
        }
    }

    /// Extract window title from an event.
    private func extractWindowTitle(from event: ObservationEvent) -> String? {
        guard case .userAction(let action) = event else { return nil }
        return action.elementTitle.isEmpty ? nil : action.elementTitle
    }

    // MARK: - Public API

    /// Get a summary of the current task for debugging/display.
    func currentTaskSummary() -> String? {
        guard let task = currentTask else { return nil }
        return "Task in \(task.primaryApp) (\(task.apps.joined(separator: "→"))) — \(task.observationCount) events, \(Int(task.duration))s, topics: \(task.topicTerms.prefix(5).joined(separator: ", "))"
    }

    /// Force a boundary (used when user explicitly says "new task" or for testing).
    func forceBoundary(reason: String = "user_request") {
        let boundary = TaskBoundary(
            kind: .hard,
            confidence: 1.0,
            trigger: .systemEvent(kind: reason),
            signals: [TaskBoundary.SignalContribution(signal: BoundarySignal.systemEvent, weight: 1.0, rawValue: 1.0)]
        )
        emitBoundary(boundary, startingApp: currentTask?.primaryApp)
    }
}
