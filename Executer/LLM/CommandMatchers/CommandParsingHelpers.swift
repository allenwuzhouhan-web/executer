import Foundation
import AppKit

/// Shared helpers used by LocalCommandRouter and its matchers.
/// Regex patterns and CharacterSets are cached as static to avoid recompilation per call.
extension LocalCommandRouter {

    // Cached regex patterns — NSRegularExpression compilation is expensive (~0.5ms each)
    private static let percentagePattern = try! NSRegularExpression(pattern: #"(\d+)\s*%?"#)
    private static let timerPattern = try! NSRegularExpression(pattern: #"(\d+)\s*(minute|min|minutes|mins|second|seconds|sec|secs|hour|hours|hr|hrs)"#)

    func matches(_ words: Set<String>, required: Set<String>) -> Bool {
        return required.isSubset(of: words)
    }

    func escapeJSON(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    func extractAfterPrefix(_ input: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if input.hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Extract a number from phrases like "set volume to 50" or "50%"
    func extractPercentage(from input: String) -> Int? {
        let nsRange = NSRange(input.startIndex..., in: input)
        if let match = Self.percentagePattern.firstMatch(in: input, range: nsRange),
           let range = Range(match.range(at: 1), in: input) {
            return Int(input[range])
        }
        // Also try "to [number]"
        if let toRange = input.range(of: "to ") {
            let afterTo = input[toRange.upperBound...]
            let numStr = afterTo.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).first ?? ""
            if let num = Int(numStr.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
                return max(0, min(100, num))
            }
        }
        return nil
    }

    /// Extract seconds from timer phrases like "5 minutes", "30 seconds", "1 hour"
    func extractTimerSeconds(from input: String) -> Int? {
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let result = Self.timerPattern.firstMatch(in: input, range: nsRange),
              let numRange = Range(result.range(at: 1), in: input),
              let unitRange = Range(result.range(at: 2), in: input) else { return nil }
        guard let num = Int(input[numRange]) else { return nil }
        let matched = String(input[unitRange])

        if matched.contains("hour") || matched.contains("hr") {
            return num * 3600
        } else if matched.contains("second") || matched.contains("sec") {
            return num
        }
        return num * 60 // minutes → seconds
    }

    func adjustVolume(delta: Int) async -> String? {
        let currentStr = (try? await GetVolumeTool().execute(arguments: "{}")) ?? ""
        let digits = currentStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let current = Int(digits) ?? 50
        let newLevel = max(0, min(100, current + delta))
        return try? await SetVolumeTool().execute(arguments: "{\"volume\": \(newLevel)}")
    }

    func adjustBrightness(delta: Int) async -> String? {
        let currentStr = (try? await GetBrightnessTool().execute(arguments: "{}")) ?? ""
        let digits = currentStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let current = Int(digits) ?? 50
        let newLevel = max(0, min(100, current + delta))
        return try? await SetBrightnessTool().execute(arguments: "{\"brightness\": \(newLevel)}")
    }

    func runAppleScript(_ script: String) async throws -> String {
        return try AppleScriptRunner.runThrowing(script)
    }
}
