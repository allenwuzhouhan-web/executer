import Foundation
import AppKit

/// Sends iMessages via AppleScript automation of Messages.app.
class IMessageService: MessagingService {
    let platform = MessagingPlatform.imessage

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Messages.app")
    }

    func sendMessage(to contact: String, text: String) async throws {
        let escapedContact = escapeForAppleScript(contact)
        let escapedText = escapeForAppleScript(text)

        // Try direct buddy-based send first
        let directScript = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escapedContact)" of targetService
            send "\(escapedText)" to targetBuddy
        end tell
        """

        do {
            try await runOsascript(directScript)
            return
        } catch {
            // Fallback to UI automation if buddy not found
            try await sendViaUI(contact: contact, text: text)
        }
    }

    // MARK: - UI Automation Fallback

    private func sendViaUI(contact: String, text: String) async throws {
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            if let saved = savedClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }

        // Activate Messages and create new message
        try await runOsascript("""
        tell application "Messages" to activate
        delay 0.5
        tell application "System Events"
            tell process "Messages"
                keystroke "n" using command down
                delay 0.3
            end tell
        end tell
        """)

        // Paste contact name
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contact, forType: .string)
        try await runOsascript("""
        tell application "System Events"
            tell process "Messages"
                keystroke "v" using command down
                delay 0.5
                key code 36
                delay 0.3
            end tell
        end tell
        """)

        // Paste message and send
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try await runOsascript("""
        tell application "System Events"
            tell process "Messages"
                keystroke "v" using command down
                delay 0.2
                key code 36
            end tell
        end tell
        """)
    }

    // MARK: - Helpers

    private func escapeForAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

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
