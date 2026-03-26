import Foundation
import AppKit

/// Handles instant responses for status queries classified by the local MLX model.
/// Composes existing SystemContext data and tools — no new tool definitions.
enum DirectResponseHandler {

    /// Returns a formatted response string for status/math categories, or nil to fall through.
    static func handle(category: String, command: String) async -> String? {
        switch category {
        case "status_time":
            return formatTime()
        case "status_battery":
            return await formatBattery()
        case "status_wifi":
            return formatWifi()
        case "status_volume":
            return formatVolume()
        case "status_app":
            return formatFrontmostApp()
        case "status_darkmode":
            return formatDarkMode()
        case "status_focus":
            return formatFocus()
        case "status_system":
            return try? await GetSystemInfoTool().execute(arguments: "{}")
        case "status_ip":
            return await formatIP()
        case "math":
            return evaluateMath(command)
        default:
            return nil
        }
    }

    // MARK: - Formatters

    private static let friendlyTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let friendlyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    private static func formatTime() -> String {
        let now = Date()
        let time = friendlyTimeFormatter.string(from: now)
        let date = friendlyDateFormatter.string(from: now)
        return "It's \(time) on \(date)."
    }

    private static func formatBattery() async -> String {
        guard let level = SystemContext.fetchBatterySync() else {
            return "Couldn't read battery level."
        }
        // Check charging status
        let charging: Bool
        if let result = try? ShellRunner.run("pmset -g batt", timeout: 5) {
            charging = result.output.contains("AC Power") || result.output.contains("charging")
        } else {
            charging = false
        }
        let chargingStr = charging ? ", charging" : ""
        return "Battery is at \(level)%\(chargingStr)."
    }

    private static func formatWifi() -> String {
        guard let network = SystemContext.fetchWifiSync() else {
            return "Not connected to Wi-Fi."
        }
        return "Connected to \(network)."
    }

    private static func formatVolume() -> String {
        let level = Int(AppleScriptRunner.run("output volume of (get volume settings)") ?? "50") ?? 50
        let muted = AppleScriptRunner.run("output muted of (get volume settings)") == "true"
        if muted {
            return "Volume is muted (set to \(level)%)."
        }
        return "Volume is at \(level)%."
    }

    private static func formatFrontmostApp() -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        return "The frontmost app is \(app)."
    }

    private static func formatDarkMode() -> String {
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return "Dark mode is \(isDark ? "on" : "off")."
    }

    private static func formatFocus() -> String {
        let focus = FocusStateService.shared.currentFocus
        if focus == .none {
            return "No Focus mode is active."
        }
        return "Focus mode: \(focus.displayName)."
    }

    private static func formatIP() async -> String {
        guard let result = try? ShellRunner.run("curl -s --max-time 3 ifconfig.me", timeout: 5) else {
            return "Couldn't determine your IP address."
        }
        let ip = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if ip.isEmpty || result.exitCode != 0 {
            return "Couldn't determine your IP address."
        }
        return "Your public IP is \(ip)."
    }

    // MARK: - Math

    private static func evaluateMath(_ command: String) -> String? {
        // Extract a math-like expression from the command
        let cleaned = command
            .lowercased()
            .replacingOccurrences(of: "what's", with: "")
            .replacingOccurrences(of: "what is", with: "")
            .replacingOccurrences(of: "calculate", with: "")
            .replacingOccurrences(of: "compute", with: "")
            .replacingOccurrences(of: "how much is", with: "")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle percentage: "15% of 240" -> "240 * 0.15"
        if let range = cleaned.range(of: #"(\d+\.?\d*)%\s*of\s*(\d+\.?\d*)"#, options: .regularExpression) {
            let match = String(cleaned[range])
            let parts = match.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if let pctStr = parts.first?.replacingOccurrences(of: "%", with: ""),
               let pct = Double(pctStr),
               let numStr = parts.last,
               let num = Double(numStr) {
                let result = num * pct / 100.0
                // Format nicely — no trailing .0 for integers
                if result == result.rounded() && result < 1e15 {
                    return "\(Int(result))"
                }
                return String(format: "%.2f", result)
            }
        }

        // Try NSExpression for standard math
        guard !cleaned.isEmpty else { return nil }
        let expr: NSExpression
        do {
            expr = NSExpression(format: cleaned)
        } catch {
            return nil
        }

        guard let result = expr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }

        let doubleVal = result.doubleValue
        if doubleVal == doubleVal.rounded() && abs(doubleVal) < 1e15 {
            return "\(result.intValue)"
        }
        return String(format: "%.4f", doubleVal)
    }
}
