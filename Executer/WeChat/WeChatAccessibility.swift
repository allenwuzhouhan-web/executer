import Cocoa
import ApplicationServices

/// WeChat automation: window off-screen, osascript via Process(), fast keystroke batching.
/// No Terminal windows. Clipboard saved/restored. Window hidden after send.
/// Requires Executer to have Accessibility permission.
enum WeChatAccessibility {

    private static let bundleId = "com.tencent.xinWeChat"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: - Send Message

    static func sendMessage(to contact: String, text: String) throws {
        guard isRunning else { throw WeChatError.notRunning }

        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved = savedClipboard { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let ec = contact.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let et = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true

            -- Ensure WeChat has a window (skip open if already visible)
            if not (exists process "WeChat") or ((count of windows of process "WeChat") is 0) then
                do shell script "open -g -a WeChat"
                repeat 15 times
                    delay 0.2
                    try
                        if (count of windows of process "WeChat") > 0 then exit repeat
                    end try
                end repeat
            end if

            -- Save position, move off-screen, activate — all in one block
            tell process "WeChat"
                set origPos to position of window 1
                if (item 1 of origPos) < -1000 then set origPos to {200, 200}
                set position of window 1 to {-30000, 0}
                set frontmost to true
            end tell
        end tell

        -- Search for contact: Cmd+F → paste name → Return → Escape (one fast batch)
        delay 0.05
        set the clipboard to "\(ec)"
        tell application "System Events" to tell process "WeChat"
            key code 3 using command down
            delay 0.2
            keystroke "v" using command down
            delay 0.4
            key code 36
            delay 0.12
            key code 53
        end tell
        delay 0.1

        -- Clear input, paste message, send (one fast batch)
        set the clipboard to "\(et)"
        tell application "System Events" to tell process "WeChat"
            keystroke "a" using command down
            delay 0.02
            key code 51
            delay 0.02
            keystroke "v" using command down
            delay 0.03
            key code 36
        end tell

        -- Restore window and hide
        delay 0.05
        tell application "System Events" to tell process "WeChat"
            set position of window 1 to origPos
            set visible to false
        end tell
        tell application frontApp to activate
        """

        try runOsascript(script)
    }

    // MARK: - Script Runner

    private static func runOsascript(_ script: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        try proc.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if proc.isRunning { proc.terminate() }
        }
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown osascript error"
            throw WeChatError.scriptFailed(errStr)
        }
    }

    // MARK: - Errors

    enum WeChatError: LocalizedError {
        case notRunning
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "WeChat is not running. Please open WeChat and log in."
            case .scriptFailed(let msg): return "WeChat send failed: \(msg)"
            }
        }
    }
}
