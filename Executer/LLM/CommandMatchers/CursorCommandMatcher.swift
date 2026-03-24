import Foundation
import AppKit

extension LocalCommandRouter {

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

        // Scroll
        if input == "scroll down" || matches(words, required: ["scroll", "down"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"down\"}")
        }
        if input == "scroll up" || matches(words, required: ["scroll", "up"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"up\"}")
        }
        if input == "scroll left" || matches(words, required: ["scroll", "left"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"left\"}")
        }
        if input == "scroll right" || matches(words, required: ["scroll", "right"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"right\"}")
        }
        // "scroll down a lot" / "scroll way down"
        if (input.contains("scroll") && input.contains("lot")) || (input.contains("scroll") && input.contains("way")) {
            let dir = input.contains("up") ? "up" : "down"
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"\(dir)\", \"amount\": 8}")
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
}
