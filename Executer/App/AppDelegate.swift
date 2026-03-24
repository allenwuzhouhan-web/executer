import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var launchGlow: LaunchGlowWindow?
    private var startupSound: StartupSound?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching")
        appState.setup()

        // AI awakening — rainbow glow + subtle chime
        launchGlow = LaunchGlowWindow()
        launchGlow?.show()
        startupSound = StartupSound()
        startupSound?.play()
        // Save weather API key on first launch
        if !WeatherKeyStore.hasKey() {
            WeatherKeyStore.setKey("WEATHER_API_KEY_REDACTED")
        }
        FocusStateService.shared.start()
        if PermissionManager.shared.accessibilityGranted {
            Task { await TextSnapshotService.shared.start() }
        }
        ClipboardHistoryManager.shared.startMonitoring()
        TaskScheduler.shared.resumePendingTasks()
        FileIndex.shared.startIndexing()
        ContextualAwareness.shared.markSessionStart()
        HealthCheckService.shared.checkIfDue(appState: appState)
        SystemEventBus.shared.start()

        print("[AppDelegate] setup complete")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
