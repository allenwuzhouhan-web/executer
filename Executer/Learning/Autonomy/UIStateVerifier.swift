import Foundation
import AppKit

/// Verifies UI state between workflow steps using ScreenReader.
enum UIStateVerifier {

    /// Verify that an expected element exists on screen.
    static func verifyElementExists(description: String, appName: String? = nil) -> Bool {
        guard let snapshot = ScreenReader.readFrontmostApp() else { return false }

        let lower = description.lowercased()
        return snapshot.elements.contains { el in
            el.title.lowercased().contains(lower) ||
            el.description.lowercased().contains(lower) ||
            el.label.lowercased().contains(lower)
        }
    }

    /// Check if the expected app is frontmost.
    static func verifyFrontmostApp(_ expectedApp: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return false }
        return name.lowercased().contains(expectedApp.lowercased())
    }

    /// Get the current screen state summary for adaptive execution.
    static func currentState() -> String {
        guard let snapshot = ScreenReader.readFrontmostApp() else { return "Unable to read screen" }
        return snapshot.summary()
    }
}
