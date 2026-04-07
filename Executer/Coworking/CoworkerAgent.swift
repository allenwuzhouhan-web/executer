import Foundation
import AppKit

/// The Coworking Agent — always-on daytime companion that watches what the user is doing
/// and proactively offers contextual help at natural pause moments.
///
/// This is the daytime counterpart to OvernightAgent. It runs as a persistent daemon
/// (not a BackgroundAgent) and surfaces suggestions through the NotchWindow indicator dot.
/// It NEVER steals focus — the user opts in by clicking the notch.
@MainActor
class CoworkerAgent: ObservableObject {
    static let shared = CoworkerAgent()

    // MARK: - Published State

    @Published var isActive = false
    @Published var isPaused = false
    @Published var currentSuggestion: CoworkingSuggestion?

    // MARK: - Configuration

    private let baseEvalInterval: TimeInterval = 30  // Check every 30s (modified by backoff)

    // MARK: - Internal

    private var evaluationTask: Task<Void, Never>?
    private var overnightObserver: Any?
    private var consumerRegistered = false

    private init() {}

    // MARK: - Lifecycle

    /// Start the coworking agent. Called from AppDelegate after permissions are granted.
    func start() {
        guard !isActive else { return }

        // Respect user preference
        guard UserDefaults.standard.object(forKey: "coworking_enabled") == nil ||
              UserDefaults.standard.bool(forKey: "coworking_enabled") else {
            print("[CoworkerAgent] Disabled by user preference")
            return
        }

        isActive = true
        isPaused = false

        // Register as observation consumer
        if !consumerRegistered {
            Task {
                await ContinuousPerceptionDaemon.shared.addConsumer(name: "coworking-workstate") { event in
                    await WorkStateEngine.shared.ingest(event)
                }
            }
            consumerRegistered = true
        }

        // Listen for overnight agent state changes
        overnightObserver = NotificationCenter.default.addObserver(
            forName: .overnightAgentStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let overnightActive = notification.userInfo?["isActive"] as? Bool ?? false
            if overnightActive {
                self.pause()
                print("[CoworkerAgent] Paused — overnight agent activated")
            } else {
                self.resume()
                print("[CoworkerAgent] Resumed — overnight agent deactivated")
            }
        }

        // Start the evaluation loop
        evaluationTask = Task { [weak self] in
            await self?.evaluationLoop()
        }

        // Start the synthesis engine (cross-domain connection finder)
        Task { await SynthesisEngine.shared.startDaytime() }

        NotificationCenter.default.post(name: .coworkerAgentStateChanged, object: nil,
                                        userInfo: ["isActive": true])
        print("[CoworkerAgent] Started — coworking mode active")
    }

    /// Stop the coworking agent completely.
    func stop() {
        guard isActive else { return }
        isActive = false
        isPaused = false

        evaluationTask?.cancel()
        evaluationTask = nil

        if let observer = overnightObserver {
            NotificationCenter.default.removeObserver(observer)
            overnightObserver = nil
        }

        if consumerRegistered {
            Task {
                await ContinuousPerceptionDaemon.shared.removeConsumer(name: "coworking-workstate")
            }
            consumerRegistered = false
        }

        // Stop the synthesis engine
        Task { await SynthesisEngine.shared.stop() }

        currentSuggestion = nil
        NotificationCenter.default.post(name: .coworkerAgentStateChanged, object: nil,
                                        userInfo: ["isActive": false])
        print("[CoworkerAgent] Stopped")
    }

    /// Pause (from overnight agent or manual toggle). Keeps consumer alive.
    func pause() {
        isPaused = true
        currentSuggestion = nil
        NotificationCenter.default.post(name: .coworkingSuggestionDismissed, object: nil)
    }

    /// Resume from pause.
    func resume() {
        isPaused = false
    }

    // MARK: - Core Evaluation Loop

    private func evaluationLoop() async {
        while isActive && !Task.isCancelled {
            // Sleep for the effective interval (accounts for backoff)
            let interval = await CoworkingSuggestionPipeline.shared.effectiveEvalInterval
            try? await Task.sleep(nanoseconds: UInt64(max(interval, baseEvalInterval) * 1_000_000_000))

            guard isActive, !isPaused, !Task.isCancelled else { continue }

            // 1. Get current work state
            let state = await WorkStateEngine.shared.snapshot()

            // 2. Check if safe to interrupt
            guard InterruptionPolicy.isSafeToInterrupt(state: state) else {
                let delay = InterruptionPolicy.retryDelay(state: state)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            // 3. Don't evaluate if we already have an active suggestion
            if let existing = currentSuggestion, !existing.isExpired {
                continue
            }

            // 4. Expire stale suggestion
            if let existing = currentSuggestion, existing.isExpired {
                await CoworkingSuggestionPipeline.shared.recordExpiry(type: existing.type)
                currentSuggestion = nil
                NotificationCenter.default.post(name: .coworkingSuggestionDismissed, object: nil)
            }

            // 5. Evaluate for a new suggestion
            if let suggestion = await CoworkingSuggestionPipeline.shared.evaluate(state: state) {
                surfaceSuggestion(suggestion)
            }
        }
    }

    // MARK: - Suggestion Surfacing

    private func surfaceSuggestion(_ suggestion: CoworkingSuggestion) {
        currentSuggestion = suggestion

        // Light up the amber dot on the notch
        NotificationCenter.default.post(name: .coworkingSuggestionAvailable, object: nil,
                                        userInfo: ["suggestion": suggestion.headline])

        // For high-confidence suggestions, also post a system notification
        if suggestion.confidence > 0.85 {
            postSystemNotification(suggestion)
        }

        print("[CoworkerAgent] Suggestion surfaced: \(suggestion.type.rawValue) — \(suggestion.headline)")
    }

    private func postSystemNotification(_ suggestion: CoworkingSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Coworker"
        content.body = suggestion.headline
        content.sound = nil  // Silent — just the banner
        content.categoryIdentifier = "coworking_suggestion"

        let request = UNNotificationRequest(
            identifier: suggestion.id.uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - User Interaction

    /// User accepted the current suggestion.
    /// No-arg version reads from `currentSuggestion` (may be nil if expired).
    func acceptSuggestion() {
        guard let suggestion = currentSuggestion else { return }
        acceptSuggestion(suggestion)
    }

    /// Accept a specific suggestion — avoids the race where `currentSuggestion`
    /// is nil'd by the evaluation loop while the card is still visible.
    func acceptSuggestion(_ suggestion: CoworkingSuggestion) {
        Task {
            await CoworkingSuggestionPipeline.shared.recordFeedback(accepted: true, type: suggestion.type)
        }

        // If the suggestion has an action command, execute it
        if let command = suggestion.actionCommand, !command.isEmpty {
            submitCommand(command)
        }

        currentSuggestion = nil
        NotificationCenter.default.post(name: .coworkingSuggestionDismissed, object: nil)
        print("[CoworkerAgent] Suggestion accepted: \(suggestion.headline)")
    }

    /// User dismissed the current suggestion.
    func dismissSuggestion() {
        guard let suggestion = currentSuggestion else { return }

        // Notify bridge so this pattern is never re-suggested
        if suggestion.type == .workflowAutomation,
           let command = suggestion.actionCommand,
           command.hasPrefix("__compress_workflow:"),
           let uuid = UUID(uuidString: String(command.dropFirst("__compress_workflow:".count))) {
            Task { await WorkflowCompressionBridge.shared.dismissPattern(uuid) }
        }

        Task {
            await CoworkingSuggestionPipeline.shared.recordFeedback(accepted: false, type: suggestion.type)
        }

        currentSuggestion = nil
        NotificationCenter.default.post(name: .coworkingSuggestionDismissed, object: nil)
        print("[CoworkerAgent] Suggestion dismissed: \(suggestion.headline)")
    }

    /// Returns the current suggestion for InputBar display, if any.
    func pendingSuggestion() -> CoworkingSuggestion? {
        guard let suggestion = currentSuggestion, !suggestion.isExpired else { return nil }
        return suggestion
    }

    // MARK: - Command Execution

    private func submitCommand(_ command: String) {
        // Handle workflow compression acceptance
        if command.hasPrefix("__compress_workflow:") {
            let patternId = String(command.dropFirst("__compress_workflow:".count))
            if let uuid = UUID(uuidString: patternId) {
                Task { await WorkflowCompressionBridge.shared.acceptPattern(uuid) }
            }
            return
        }

        // Bypass research/browser/local routing — coworking action commands are
        // multi-step agent instructions, not short user queries.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.appState.executeDirectCommand(command)
        }
    }
}

// MARK: - UNUserNotificationCenter Import

import UserNotifications
