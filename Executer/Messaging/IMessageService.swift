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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MessagingError.sendFailed(msg)
        }
    }
}
