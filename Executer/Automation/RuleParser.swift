import Foundation

/// Parses natural language "when X, do Y" strings into structured trigger-action pairs.
struct RuleParser {

    struct ParseResult {
        let trigger: RuleTrigger
        let actions: [RuleAction]
    }

    /// Attempts to parse a natural language rule. Returns nil if unparseable.
    static func parse(_ input: String) -> ParseResult? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Split into trigger and action parts
        // Look for common separators: ", " after "when" clause, or "then"
        guard let (triggerPart, actionPart) = splitTriggerAction(lower) else {
            return nil
        }

        guard let trigger = parseTrigger(triggerPart) else { return nil }
        let actions = parseActions(actionPart)
        guard !actions.isEmpty else { return nil }

        return ParseResult(trigger: trigger, actions: actions)
    }

    // MARK: - Split trigger/action

    private static func splitTriggerAction(_ input: String) -> (trigger: String, action: String)? {
        // Try splitting on ", " after "when" clause
        // "when I connect my monitor, open Xcode and Terminal"
        // "every day at 9am, open Mail"

        // Try "then" first
        if let range = input.range(of: " then ") {
            let trigger = String(input[..<range.lowerBound])
            let action = String(input[range.upperBound...])
            if !trigger.isEmpty && !action.isEmpty { return (trigger, action) }
        }

        // Try ", " split — find the first comma after a trigger phrase
        let triggerPrefixes = ["when ", "every ", "at ", "if "]
        for prefix in triggerPrefixes {
            if input.hasPrefix(prefix), let commaRange = input.range(of: ", ") {
                let trigger = String(input[..<commaRange.lowerBound])
                let action = String(input[commaRange.upperBound...])
                if !trigger.isEmpty && !action.isEmpty { return (trigger, action) }
            }
        }

        // Try just "when X do Y"
        if let range = input.range(of: " do ") {
            let trigger = String(input[..<range.lowerBound])
            let action = String(input[range.upperBound...])
            if !trigger.isEmpty && !action.isEmpty { return (trigger, action) }
        }

        return nil
    }

    // MARK: - Trigger parsing

    private static func parseTrigger(_ input: String) -> RuleTrigger? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Display
        if containsAny(s, ["connect", "plug in", "attach"]) && containsAny(s, ["monitor", "display", "screen", "external"]) {
            return .displayConnected
        }
        if containsAny(s, ["disconnect", "unplug", "detach", "remove"]) && containsAny(s, ["monitor", "display", "screen", "external"]) {
            return .displayDisconnected
        }

        // Wi-Fi
        if containsAny(s, ["connect", "join"]) && containsAny(s, ["wifi", "wi-fi", "network"]) {
            let name = extractQuoted(s) ?? extractAfter(s, markers: ["to ", "network "])
            return .wifiConnected(networkName: name)
        }
        if containsAny(s, ["disconnect"]) && containsAny(s, ["wifi", "wi-fi", "network"]) {
            return .wifiDisconnected
        }

        // Time of day
        if let (hour, minute) = parseTime(s) {
            return .timeOfDay(hour: hour, minute: minute)
        }

        // App launch
        if containsAny(s, ["open", "launch", "start"]) {
            if let appName = extractAppName(s, verbs: ["open", "launch", "start"]) {
                return .appLaunched(appName: appName)
            }
        }

        // App quit
        if containsAny(s, ["close", "quit", "exit"]) {
            if let appName = extractAppName(s, verbs: ["close", "quit", "exit"]) {
                return .appQuit(appName: appName)
            }
        }

        // Battery
        if containsAny(s, ["battery"]) && containsAny(s, ["below", "under", "drops", "low", "less"]) {
            if let pct = extractNumber(s) {
                return .batteryLow(threshold: pct)
            }
            return .batteryLow(threshold: 20) // default
        }

        // Power
        if containsAny(s, ["plug in", "connect", "attach"]) && containsAny(s, ["charger", "power", "cable", "adapter"]) {
            return .powerConnected
        }
        if containsAny(s, ["unplug", "disconnect"]) && containsAny(s, ["charger", "power", "cable", "adapter"]) {
            return .powerDisconnected
        }

        // Screen lock/unlock
        if containsAny(s, ["lock"]) && containsAny(s, ["screen", "mac", "computer"]) {
            return .screenLocked
        }
        if containsAny(s, ["unlock"]) && containsAny(s, ["screen", "mac", "computer"]) {
            return .screenUnlocked
        }
        if s.contains("unlock") && !s.contains("lock my") {
            return .screenUnlocked
        }

        // Focus
        if containsAny(s, ["focus", "do not disturb", "dnd"]) && containsAny(s, ["change", "switch", "turn", "enable"]) {
            let mode = extractQuoted(s)
            return .focusChanged(mode: mode)
        }

        return nil
    }

    // MARK: - Action parsing

    private static func parseActions(_ input: String) -> [RuleAction] {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on " and " to get multiple actions: "open Xcode and Terminal"
        // But be careful: "open Xcode and Terminal" = two launch actions
        // vs "open Xcode and set volume to 50" = launch + volume

        var actions: [RuleAction] = []

        // Check for compound "open X and Y" pattern
        let openPrefixes = ["open ", "launch ", "start "]
        for prefix in openPrefixes {
            if s.hasPrefix(prefix) {
                let rest = String(s.dropFirst(prefix.count))
                // Check if this is "open X and Y" where both X and Y are app names
                let parts = rest.components(separatedBy: " and ")
                if parts.count >= 2 && parts.allSatisfy({ isLikelyAppName($0) }) {
                    for part in parts {
                        actions.append(.launchApp(name: capitalize(part.trimmingCharacters(in: .whitespaces))))
                    }
                    return actions
                }
                // Single app
                actions.append(.launchApp(name: capitalize(rest.trimmingCharacters(in: .whitespaces))))
                return actions
            }
        }

        // Quit app
        let quitPrefixes = ["quit ", "close ", "kill "]
        for prefix in quitPrefixes {
            if s.hasPrefix(prefix) {
                let appName = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                actions.append(.quitApp(name: capitalize(appName)))
                return actions
            }
        }

        // Volume
        if containsAny(s, ["volume"]) {
            if let level = extractNumber(s) {
                actions.append(.setVolume(level: level))
                return actions
            }
        }

        // Dark mode
        if containsAny(s, ["dark mode"]) {
            actions.append(.toggleDarkMode)
            return actions
        }

        // Notification
        if s.hasPrefix("notify") || s.hasPrefix("alert") || s.hasPrefix("remind") {
            let body = s.replacingOccurrences(of: "notify me ", with: "")
                .replacingOccurrences(of: "notify ", with: "")
                .replacingOccurrences(of: "alert me ", with: "")
            actions.append(.showNotification(title: "Automation", body: body))
            return actions
        }

        // Fallback: treat entire action string as a natural language command for the LLM
        if !s.isEmpty {
            actions.append(.naturalLanguage(command: s))
        }

        return actions
    }

    // MARK: - Helpers

    private static func containsAny(_ string: String, _ keywords: [String]) -> Bool {
        keywords.contains { string.contains($0) }
    }

    private static func extractQuoted(_ string: String) -> String? {
        if let range = string.range(of: "\"[^\"]+\"", options: .regularExpression) {
            return String(string[range]).replacingOccurrences(of: "\"", with: "")
        }
        if let range = string.range(of: "'[^']+'", options: .regularExpression) {
            return String(string[range]).replacingOccurrences(of: "'", with: "")
        }
        return nil
    }

    private static func extractAfter(_ string: String, markers: [String]) -> String? {
        for marker in markers {
            if let range = string.range(of: marker) {
                let after = String(string[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let word = after.components(separatedBy: " ").first ?? ""
                if !word.isEmpty { return word }
            }
        }
        return nil
    }

    private static func extractNumber(_ string: String) -> Int? {
        if let range = string.range(of: #"\d+"#, options: .regularExpression) {
            return Int(String(string[range]))
        }
        return nil
    }

    private static func extractAppName(_ string: String, verbs: [String]) -> String? {
        var s = string
        // Remove "when i" / "when my" prefix
        for prefix in ["when i ", "when my ", "when "] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        for verb in verbs {
            if s.hasPrefix(verb + " ") {
                let name = String(s.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return capitalize(name) }
            }
        }
        return nil
    }

    private static func parseTime(_ string: String) -> (Int, Int)? {
        // "every day at 9am" / "at 9:30 pm" / "every day at 14:00"
        // Look for time pattern
        if let range = string.range(of: #"\d{1,2}:\d{2}\s*(am|pm)?"#, options: [.regularExpression, .caseInsensitive]) {
            let timeStr = String(string[range]).lowercased()
            let parts = timeStr.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ":")
            guard parts.count == 2, var hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            if timeStr.contains("pm") && hour < 12 { hour += 12 }
            if timeStr.contains("am") && hour == 12 { hour = 0 }
            return (hour, minute)
        }
        // "9am" / "9pm" / "9 am"
        if let range = string.range(of: #"\d{1,2}\s*(am|pm)"#, options: [.regularExpression, .caseInsensitive]) {
            let timeStr = String(string[range]).lowercased().trimmingCharacters(in: .whitespaces)
            let numStr = timeStr.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard var hour = Int(numStr) else { return nil }
            if timeStr.contains("pm") && hour < 12 { hour += 12 }
            if timeStr.contains("am") && hour == 12 { hour = 0 }
            return (hour, 0)
        }
        return nil
    }

    private static func isLikelyAppName(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // An app name is usually 1-3 words, starts with capital or is all lowercase
        let words = trimmed.components(separatedBy: " ")
        return words.count <= 3 && !trimmed.isEmpty && !containsAny(trimmed, ["set ", "turn ", "toggle ", "run "])
    }

    private static func capitalize(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
