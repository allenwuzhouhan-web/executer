import Foundation
import AppKit

struct SystemContext {
    let frontmostApp: String
    let currentTime: String
    let isDarkMode: Bool
    let volumeLevel: Int
    let clipboardPreview: String?
    let frontmostWindowTitle: String?
    let terminalCWD: String?
    let finderSelection: String?
    let batteryLevel: Int?
    let wifiNetworkName: String?
    let activeDisplayCount: Int
    let focusMode: String?

    static func current() -> SystemContext {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let time = formatter.string(from: Date())

        let darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        let volume = AppleScriptRunner.run("output volume of (get volume settings)") ?? "50"

        // Clipboard preview (first 200 chars)
        let clipboard: String? = {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
            let preview = text.prefix(200)
            return preview.count < text.count ? "\(preview)..." : String(preview)
        }()

        // Frontmost window title
        let windowTitle: String? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            let script = "tell application \"System Events\" to get name of front window of (first process whose unix id is \(app.processIdentifier))"
            return AppleScriptRunner.run(script)
        }()

        // Terminal CWD (if Terminal is frontmost)
        let cwd: String? = {
            guard frontApp == "Terminal" else { return nil }
            return AppleScriptRunner.run("tell application \"Terminal\" to get custom title of selected tab of front window")
        }()

        // Finder selection (if Finder is frontmost)
        let finderSel: String? = {
            guard frontApp == "Finder" else { return nil }
            return AppleScriptRunner.run("tell application \"Finder\" to get POSIX path of (selection as alias)")
        }()

        // Battery level
        let battery: Int? = {
            guard let result = try? ShellRunner.run("pmset -g batt", timeout: 5) else { return nil }
            guard let range = result.output.range(of: #"\d+%"#, options: .regularExpression) else { return nil }
            let pctStr = String(result.output[range]).replacingOccurrences(of: "%", with: "")
            return Int(pctStr)
        }()

        // Wi-Fi network name
        let wifi: String? = {
            guard let result = try? ShellRunner.run("networksetup -getairportnetwork en0", timeout: 5) else { return nil }
            if result.output.contains("Current Wi-Fi Network:") {
                return result.output.replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        // Display count
        let displayCount = NSScreen.screens.count

        // Focus mode
        let focus = FocusStateService.shared.currentFocus
        let focusStr: String? = focus == .none ? nil : focus.displayName

        return SystemContext(
            frontmostApp: frontApp,
            currentTime: time,
            isDarkMode: darkMode,
            volumeLevel: Int(volume) ?? 50,
            clipboardPreview: clipboard,
            frontmostWindowTitle: windowTitle,
            terminalCWD: cwd,
            finderSelection: finderSel,
            batteryLevel: battery,
            wifiNetworkName: wifi,
            activeDisplayCount: displayCount,
            focusMode: focusStr
        )
    }

    var systemPromptAddendum: String {
        var lines = [
            "Current context:",
            "- Frontmost app: \(frontmostApp)",
            "- Time: \(currentTime)",
            "- Dark mode: \(isDarkMode ? "on" : "off")",
            "- Volume: \(volumeLevel)%",
        ]
        if let title = frontmostWindowTitle {
            lines.append("- Window title: \(title)")
        }
        if let clipboard = clipboardPreview {
            lines.append("- Clipboard: \(clipboard)")
        }
        if let cwd = terminalCWD {
            lines.append("- Terminal CWD: \(cwd)")
        }
        if let sel = finderSelection {
            lines.append("- Finder selection: \(sel)")
        }
        if let battery = batteryLevel {
            lines.append("- Battery: \(battery)%")
        }
        if let wifi = wifiNetworkName {
            lines.append("- Wi-Fi: \(wifi)")
        }
        if activeDisplayCount > 1 {
            lines.append("- Displays: \(activeDisplayCount)")
        }
        if let focus = focusMode {
            lines.append("- Focus mode: \(focus)")
        }

        // Include top-level Documents folder structure so the AI knows where files are
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let docsPath = "\(home)/Documents"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: docsPath) {
            let folders = contents
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .prefix(30)
            if !folders.isEmpty {
                lines.append("- Documents folders: \(folders.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
