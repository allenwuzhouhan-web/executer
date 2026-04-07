import Foundation
import AppKit

extension LocalCommandRouter {

    // Cached regex for scroll amounts: "scroll down 5", "scroll up 3 times"
    private static let scrollAmountPattern = try! NSRegularExpression(pattern: #"(\d+)\s*(times?)?"#)

    func tryCursorCommand(_ input: String, words: Set<String>) async -> String? {
        // Click
        if input == "click" || input == "click here" {
            return try? await ClickTool().execute(arguments: "{}")
        }
        if input == "double click" || input == "double-click" {
            return try? await ClickTool().execute(arguments: "{\"count\": 2}")
        }
        if input == "right click" || input == "right-click" {
            return try? await ClickTool().execute(arguments: "{\"button\": \"right\"}")
        }
        if input == "triple click" || input == "triple-click" {
            return try? await ClickTool().execute(arguments: "{\"count\": 3}")
        }

        // --- Dynamic scroll ---
        if input.contains("scroll") {
            // "scroll to top" / "scroll to bottom"
            if input.contains("to top") || input.contains("to the top") {
                return try? await ScrollTool().execute(arguments: "{\"direction\": \"up\", \"amount\": 10}")
            }
            if input.contains("to bottom") || input.contains("to the bottom") {
                return try? await ScrollTool().execute(arguments: "{\"direction\": \"down\", \"amount\": 10}")
            }

            // Determine direction
            let direction: String
            if input.contains("up") { direction = "up" }
            else if input.contains("left") { direction = "left" }
            else if input.contains("right") { direction = "right" }
            else { direction = "down" } // default

            // Determine amount dynamically
            let amount: Int
            if input.contains("a lot") || input.contains("way ") || input.contains("a page") || input.contains("page ") {
                amount = 8
            } else if input.contains("a little") || input.contains("slightly") || input.contains("a bit") {
                amount = 1
            } else if let parsed = Self.parseScrollAmount(input) {
                amount = min(10, max(1, parsed))
            } else {
                amount = 3
            }

            return try? await ScrollTool().execute(arguments: "{\"direction\": \"\(direction)\", \"amount\": \(amount)}")
        }

        // Move cursor to center
        if input == "move cursor to center" || input == "center cursor" || matches(words, required: ["cursor", "center"]) {
            if let screen = NSScreen.main {
                let x = Int(screen.frame.width / 2)
                let y = Int(screen.frame.height / 2)
                return try? await MoveCursorTool().execute(arguments: "{\"x\": \(x), \"y\": \(y)}")
            }
        }

        // Where is cursor
        if input == "where is my cursor" || input == "cursor position" || input == "where's the cursor" ||
           matches(words, required: ["cursor", "position"]) {
            return try? await GetCursorPositionTool().execute(arguments: "{}")
        }

        // "click on [element]"
        if input.hasPrefix("click on ") || input.hasPrefix("click the ") || input.hasPrefix("press the ") || input.hasPrefix("tap ") {
            let desc = input
                .replacingOccurrences(of: "click on ", with: "")
                .replacingOccurrences(of: "click the ", with: "")
                .replacingOccurrences(of: "press the ", with: "")
                .replacingOccurrences(of: "tap ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return try? await ClickElementTool().execute(arguments: "{\"description\": \"\(escapeJSON(desc))\"}")
            }
        }

        return nil
    }

    /// Extracts a numeric scroll amount from phrases like "scroll down 5" or "scroll up 3 times"
    private static func parseScrollAmount(_ input: String) -> Int? {
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let match = scrollAmountPattern.firstMatch(in: input, range: nsRange),
              let numRange = Range(match.range(at: 1), in: input),
              let num = Int(input[numRange]) else { return nil }
        return num
    }
}
