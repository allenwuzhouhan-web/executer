import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var launchGlow: LaunchGlowWindow?
    private var startupSound: StartupSound?
    private var permissionSetup: PermissionSetupWindowController?
    private var welcomeWindow: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching")
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

        // Show welcome on first launch
        if !UserDefaults.standard.bool(forKey: "has_completed_onboarding") {
            welcomeWindow = WelcomeWindowController()
            welcomeWindow?.show { [weak self] in
                self?.welcomeWindow = nil
                // After onboarding, proceed to permission setup
                self?.showPermissionSetupIfNeeded()
            }
        } else {
            showPermissionSetupIfNeeded()
        }

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
