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
