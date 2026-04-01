import Foundation
import AppKit

/// Sends WhatsApp messages via Accessibility automation of WhatsApp.app.
class WhatsAppService: MessagingService {
    let platform = MessagingPlatform.whatsapp
    private let bundleId = "net.whatsapp.WhatsApp"

    var isAvailable: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    func sendMessage(to contact: String, text: String) async throws {
        guard isAvailable else {
            throw MessagingError.platformNotAvailable("WhatsApp is not running.")
        }

        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            if let saved = savedClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }

        // Activate WhatsApp and open search
        try await runOsascript("""
        tell application "WhatsApp" to activate
        delay 0.5
        tell application "System Events"
            tell process "WhatsApp"
                keystroke "f" using command down
                delay 0.3
            end tell
        end tell
        """)

        // Paste contact name and select
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contact, forType: .string)
        try await runOsascript("""
        tell application "System Events"
            tell process "WhatsApp"
                keystroke "v" using command down
                delay 0.8
                key code 36
                delay 0.5
            end tell
        end tell
        """)

        // Paste message and send
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try await runOsascript("""
        tell application "System Events"
            tell process "WhatsApp"
                keystroke "v" using command down
                delay 0.2
                key code 36
            end tell
        end tell
        """)

        // Minimize WhatsApp
        try? await runOsascript("""
        tell application "WhatsApp" to set miniaturized of window 1 to true
        """)
    }

    // MARK: - Helpers

    private func runOsascript(_ script: String) async throws {
        // Use NSAppleScript (in-process) to inherit Executer's Accessibility permission.
        // /usr/bin/osascript subprocess requires its own Accessibility entry on macOS Sequoia+.
        var errorDict: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&errorDict)

        if let err = errorDict {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let code = err[NSAppleScript.errorNumber] as? Int ?? -1
            if code != -128 {
                throw MessagingError.sendFailed(msg)
            }
        }
    }
}
