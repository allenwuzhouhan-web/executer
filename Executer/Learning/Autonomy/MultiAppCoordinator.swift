import Foundation

/// Manages app switching, clipboard passing, and timing between apps
/// during multi-app workflow execution.
enum MultiAppCoordinator {

    /// Delay between app operations to allow UI to settle.
    static let interAppDelay: TimeInterval = 0.5
    static let uiSettleDelay: TimeInterval = 0.3

    /// Switch to an app and wait for it to become frontmost.
    static func switchToApp(_ appName: String, timeout: TimeInterval = 5.0) async -> Bool {
        // The actual switching is done via tools, this coordinates timing
        try? await Task.sleep(nanoseconds: UInt64(interAppDelay * 1_000_000_000))
        return UIStateVerifier.verifyFrontmostApp(appName)
    }

    /// Wait for UI to settle after an action.
    static func waitForUISettle() async {
        try? await Task.sleep(nanoseconds: UInt64(uiSettleDelay * 1_000_000_000))
    }
}
