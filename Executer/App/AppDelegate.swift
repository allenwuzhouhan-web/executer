import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var launchGlow: LaunchGlowWindow?
    private var startupSound: StartupSound?
    private var permissionSetup: PermissionSetupWindowController?
    private var welcomeWindow: WelcomeWindowController?
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

        // Generate device serial on first launch (before welcome screen needs it)
        _ = DeviceSerial.serial

        appState.setup()

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
        FileIndex.shared.startIndexing()
        ContextualAwareness.shared.markSessionStart()
        HealthCheckService.shared.checkIfDue(appState: appState)
        NewsBriefingService.shared.checkIfDue(appState: appState)
        SystemEventBus.shared.start()
        Task { await WeChatService.shared.initialize() }

        // Always show welcome first on first launch or version change.
        // Permission setup comes AFTER welcome completes (or immediately if no welcome needed).
        let lastOnboardedVersion = UserDefaults.standard.string(forKey: "onboarded_version") ?? ""
        let needsOnboarding = !UserDefaults.standard.bool(forKey: "has_completed_onboarding") || lastOnboardedVersion != AppModel.version

        // Start permission-dependent services regardless of welcome state
        // (permissions may already be granted from previous install)
        showPermissionSetupIfNeeded()

        // Show welcome on top if needed (doesn't block permissions)
        if needsOnboarding {
            // Delay to ensure welcome appears ABOVE permission window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.welcomeWindow = WelcomeWindowController()
                self?.welcomeWindow?.show {
                    self?.welcomeWindow = nil
                }
                // Welcome window is already .floating level from WelcomeWindowController
            }
        }

        print("[AppDelegate] needsOnboarding=\(needsOnboarding), lastVersion=\(lastOnboardedVersion), current=\(AppModel.version)")

        // Check for updates silently on launch
        AppUpdater.shared.checkForUpdates()

        print("[AppDelegate] setup complete")
    }

    /// One-time permission setup — shows a guided window if Accessibility or
    /// Input Monitoring are missing. Auto-closes when granted.
    private func showPermissionSetupIfNeeded() {
        permissionSetup = PermissionSetupWindowController()
        permissionSetup?.showIfNeeded { [weak self] in
            self?.startPermissionDependentServices()
            self?.permissionSetup = nil
        }
    }

    /// Start services that require Accessibility / Input Monitoring.
    private func startPermissionDependentServices() {
        if PermissionManager.shared.accessibilityGranted {
            Task { await TextSnapshotService.shared.start() }
            // Start background learning — observes how user interacts with apps
            LearningManager.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LearningManager.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
