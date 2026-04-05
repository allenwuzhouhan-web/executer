import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let appState = AppState()
    private var launchGlow: LaunchGlowWindow?
    private var startupSound: StartupSound?
    private var onboardingWindow: OnboardingWindowController?
    private var lockdownWindow: LockdownWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching")

        // SECURITY: Verify system integrity before ANYTHING else
        let integrityResult = IntegrityChecker.verify()
        if case .failed(let reason) = integrityResult {
            lockdownWindow = LockdownWindow()
            lockdownWindow?.show(reason: reason)
            return  // DO NOT proceed with app launch
        }

        // Async manifest verification (release builds only) — runs in background, doesn't block launch
        Task.detached(priority: .utility) { [weak self] in
            let asyncResult = await IntegrityChecker.verifyAsync()
            if case .failed(let reason) = asyncResult {
                await MainActor.run {
                    self?.lockdownWindow = LockdownWindow()
                    self?.lockdownWindow?.show(reason: reason)
                }
            }
        }

        // Generate device serial on first launch (before welcome screen needs it)
        _ = DeviceSerial.serial

        // Set notification delegate so alarms/timers fire even when app is in foreground
        UNUserNotificationCenter.current().delegate = self

        appState.setup()

        // Connect to MCP servers in the background, then register discovered tools
        Task.detached(priority: .utility) {
            await MCPServerManager.shared.connectAll()
            let mcpTools = await MCPServerManager.shared.getDiscoveredTools()
            if !mcpTools.isEmpty {
                await MainActor.run {
                    ToolRegistry.shared.registerMCPTools(mcpTools)
                }
            }
        }

        // AI awakening — rainbow glow + subtle chime
        launchGlow = LaunchGlowWindow()
        launchGlow?.show()
        startupSound = StartupSound()
        startupSound?.play()

        // Pre-load formula database (checks disk, builds index)
        _ = FormulaDatabase.shared

        // Start services that don't need special permissions
        FocusStateService.shared.start()
        ClipboardHistoryManager.shared.startMonitoring()
        TaskScheduler.shared.resumePendingTasks()
        BackgroundAgentManager.shared.resumePendingAgents()
        FileIndex.shared.startIndexing()
        ContextualAwareness.shared.markSessionStart()
        HealthCheckService.shared.checkIfDue(appState: appState)
        NewsBriefingService.shared.checkIfDue(appState: appState)
        SystemEventBus.shared.start()
        Task { await WeChatService.shared.initialize() }

        // Unified onboarding: single window for welcome + permissions
        let lastOnboardedVersion = UserDefaults.standard.string(forKey: "onboarded_version") ?? ""
        let needsOnboarding = !UserDefaults.standard.bool(forKey: "has_completed_onboarding") || lastOnboardedVersion != AppModel.version
        let pm = PermissionManager.shared
        pm.refreshAccessibility()
        pm.refreshEventTap()
        let permissionsMissing = !pm.accessibilityGranted || !pm.eventTapAvailable

        if needsOnboarding || permissionsMissing {
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.show { [weak self] in
                self?.startPermissionDependentServices()
                self?.onboardingWindow = nil
            }
        } else {
            // Permissions already granted, no onboarding needed
            startPermissionDependentServices()
        }

        print("[AppDelegate] needsOnboarding=\(needsOnboarding), permissionsMissing=\(permissionsMissing), lastVersion=\(lastOnboardedVersion), current=\(AppModel.version)")

        // Start runtime protection (periodic tamper checks for release builds)
        RuntimeShield.startPeriodicChecks()
        EnvironmentIntegrity.startFileMonitoring()

        // Check for updates silently on launch
        AppUpdater.shared.checkForUpdates()

        print("[AppDelegate] setup complete")
    }

    /// Start services that require Accessibility / Input Monitoring.
    private func startPermissionDependentServices() {
        if PermissionManager.shared.accessibilityGranted {
            Task { await TextSnapshotService.shared.start() }
            // Start background learning — observes how user interacts with apps
            LearningManager.shared.start()
            // Start coworking agent — daytime proactive assistant
            Task { @MainActor in CoworkerAgent.shared.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RuntimeShield.stopPeriodicChecks()
        EnvironmentIntegrity.stopFileMonitoring()
        // Persist running agent sessions so they can resume after restart
        appState.persistRunningSession()
        Task { await AuditLog.shared.persistToDisk() }
        LearningManager.shared.stop()
        Task { await BrowserService.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification banner + play sound even when app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
