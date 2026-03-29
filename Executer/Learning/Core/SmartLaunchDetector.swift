import Foundation
import AppKit

/// Detects when key productivity apps launch and triggers focused learning sessions.
/// Shows a subtle notification asking if the user wants to start a learning session.
final class SmartLaunchDetector {
    static let shared = SmartLaunchDetector()

    /// Apps that trigger focused learning prompts.
    /// Maps bundle ID prefixes to display names and learning categories.
    private let trackedApps: [(bundlePrefix: String, name: String, category: String)] = [
        ("com.microsoft.PowerPoint", "PowerPoint", "presentation"),
        ("com.apple.iWork.Keynote", "Keynote", "presentation"),
        ("com.google.Chrome", "Chrome", "research"),
        ("com.apple.Safari", "Safari", "research"),
        ("com.microsoft.Word", "Word", "writing"),
        ("com.apple.iWork.Pages", "Pages", "writing"),
        ("com.microsoft.Excel", "Excel", "data_analysis"),
        ("com.apple.iWork.Numbers", "Numbers", "data_analysis"),
        ("com.apple.dt.Xcode", "Xcode", "coding"),
        ("com.microsoft.VSCode", "VS Code", "coding"),
        ("com.todesktop.230313mzl4w4u92", "Cursor", "coding"),
    ]

    /// Cooldown per app — don't prompt again within this window.
    private var lastPromptTime: [String: Date] = [:]
    private let promptCooldown: TimeInterval = 3600  // 1 hour between prompts for same app

    /// Track which apps have been seen before (first launch gets extra attention).
    private var knownApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "learning_known_apps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "learning_known_apps") }
    }

    /// How many days since learning was first enabled.
    var daysSinceLearningStarted: Int {
        let startDate = UserDefaults.standard.object(forKey: "learning_first_start") as? Date ?? Date()
        return Calendar.current.dateComponents([.day], from: startDate, to: Date()).day ?? 0
    }

    /// Whether we're in the intensive first-week learning period.
    var isFirstWeek: Bool {
        daysSinceLearningStarted < 7
    }

    private init() {
        // Record first learning start date if not set
        if UserDefaults.standard.object(forKey: "learning_first_start") == nil {
            UserDefaults.standard.set(Date(), forKey: "learning_first_start")
        }
    }

    // MARK: - Start / Stop

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        print("[SmartLaunch] Monitoring app launches")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - App Launch Handling

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              let appName = app.localizedName else { return }

        // Check if this is a tracked productivity app
        guard let tracked = trackedApps.first(where: { bundleId.hasPrefix($0.bundlePrefix) }) else { return }

        // Check cooldown
        if let lastTime = lastPromptTime[bundleId],
           Date().timeIntervalSince(lastTime) < promptCooldown { return }

        lastPromptTime[bundleId] = Date()

        let isNewApp = !knownApps.contains(bundleId)
        if isNewApp {
            var known = knownApps
            known.insert(bundleId)
            knownApps = known
        }

        // During first week, auto-boost sampling without asking
        if isFirstWeek {
            boostLearning(for: tracked.name, category: tracked.category, appName: appName)
            return
        }

        // After first week, show a subtle notification for new or important sessions
        if isNewApp || tracked.category == "presentation" {
            showLearningPrompt(for: tracked.name, category: tracked.category, appName: appName)
        }
    }

    // MARK: - Learning Actions

    /// Auto-boost learning intensity (used during first week).
    private func boostLearning(for trackedName: String, category: String, appName: String) {
        // Increase screen sampling to 10s for this session
        AdaptiveSampling.shared.boostForApp(appName)

        // Create a focused observation note
        let obs = SemanticObservation(
            appName: appName,
            category: TopicClassifier.classifyApp(appName),
            intent: "Opened \(trackedName) — intensive learning active",
            details: ["category": category, "firstWeek": "true"],
            relatedTopics: [trackedName.lowercased(), category]
        )
        AttentionTracker.shared.record([obs])
        SessionDetector.shared.ingest([obs])

        print("[SmartLaunch] Auto-boosted learning for \(trackedName) (first week)")
    }

    /// Show a subtle notification offering focused learning.
    private func showLearningPrompt(for trackedName: String, category: String, appName: String) {
        // Post a notification that the UI can pick up
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .smartLaunchDetected,
                object: nil,
                userInfo: [
                    "appName": appName,
                    "trackedName": trackedName,
                    "category": category,
                ]
            )
        }

        // Also boost sampling automatically for tracked apps
        AdaptiveSampling.shared.boostForApp(appName)

        print("[SmartLaunch] Learning prompt for \(trackedName)")
    }
}

extension Notification.Name {
    static let smartLaunchDetected = Notification.Name("com.executer.smartLaunchDetected")
}
