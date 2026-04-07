import Foundation

extension LocalCommandRouter {

    func tryWindowCommand(_ input: String, words: Set<String>) async -> String? {

        // --- Exit / leave fullscreen (must come before enter fullscreen) ---
        if input == "exit fullscreen" || input == "leave fullscreen" || input == "unfullscreen" ||
           input == "exit full screen" || input == "leave full screen" ||
           matches(words, required: ["exit", "fullscreen"]) || matches(words, required: ["leave", "fullscreen"]) {
            // Exit fullscreen is just toggling fullscreen again on the current window
            return try? await FullscreenWindowTool().execute(arguments: "{}")
        }

        // --- Fullscreen ---
        if input == "fullscreen" || input == "full screen" || input == "go fullscreen" || input == "go full screen" ||
           input == "make this fullscreen" || input == "make this full screen" ||
           input == "enter fullscreen" || input == "enter full screen" ||
           input == "make fullscreen" || input == "make it fullscreen" ||
           matches(words, required: ["make", "fullscreen"]) || matches(words, required: ["enter", "fullscreen"]) ||
           matches(words, required: ["go", "fullscreen"]) {
            return try? await FullscreenWindowTool().execute(arguments: "{}")
        }
        // "fullscreen [app]" / "make [app] fullscreen"
        if input.hasPrefix("fullscreen ") {
            let appName = String(input.dropFirst("fullscreen ".count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty {
                return try? await FullscreenWindowTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }
        if input.hasPrefix("make ") && (input.hasSuffix(" fullscreen") || input.hasSuffix(" full screen")) {
            let suffix = input.hasSuffix(" fullscreen") ? " fullscreen" : " full screen"
            let appName = String(input.dropFirst("make ".count).dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && appName != "this" && appName != "it" {
                return try? await FullscreenWindowTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Minimize ---
        if input == "minimize" || input == "minimize this" || input == "minimize window" ||
           input == "minimize this window" || input == "minimize the window" ||
           matches(words, required: ["minimize", "window"]) {
            return try? await MinimizeWindowTool().execute(arguments: "{}")
        }
        if input.hasPrefix("minimize ") {
            let appName = extractAfterPrefix(input, prefixes: ["minimize "])
            if let appName = appName, !appName.isEmpty && appName != "this" && appName != "window" && appName != "this window" && appName != "the window" {
                return try? await MinimizeWindowTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Close window ---
        if input == "close window" || input == "close this window" || input == "close the window" ||
           matches(words, required: ["close", "window"]) {
            return try? await CloseWindowTool().execute(arguments: "{}")
        }
        // "close [app] window"
        if input.hasPrefix("close ") && input.hasSuffix(" window") {
            let appName = String(input.dropFirst("close ".count).dropLast(" window".count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && appName != "this" && appName != "the" {
                return try? await CloseWindowTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Center window ---
        if input == "center window" || input == "center this" || input == "center the window" ||
           input == "center this window" || input == "center" ||
           matches(words, required: ["center", "window"]) {
            return try? await CenterWindowTool().execute(arguments: "{}")
        }
        if input.hasPrefix("center ") {
            let appName = extractAfterPrefix(input, prefixes: ["center "])
            if let appName = appName, !appName.isEmpty && appName != "this" && appName != "window" && appName != "the window" && appName != "this window" {
                return try? await CenterWindowTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Tile left ---
        if input == "tile left" || input == "snap left" || input == "left half" ||
           input == "move window left" || input == "window to left half" ||
           input == "tile window left" || input == "snap window left" ||
           input == "move to left half" || input == "left side" ||
           matches(words, required: ["tile", "left"]) || matches(words, required: ["snap", "left"]) {
            return try? await TileWindowLeftTool().execute(arguments: "{}")
        }
        // "tile [app] left" / "snap [app] left"
        if (input.hasPrefix("tile ") || input.hasPrefix("snap ")) && input.hasSuffix(" left") {
            let prefix = input.hasPrefix("tile ") ? "tile " : "snap "
            let appName = String(input.dropFirst(prefix.count).dropLast(" left".count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && appName != "window" {
                return try? await TileWindowLeftTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Tile right ---
        if input == "tile right" || input == "snap right" || input == "right half" ||
           input == "move window right" || input == "window to right half" ||
           input == "tile window right" || input == "snap window right" ||
           input == "move to right half" || input == "right side" ||
           matches(words, required: ["tile", "right"]) || matches(words, required: ["snap", "right"]) {
            return try? await TileWindowRightTool().execute(arguments: "{}")
        }
        if (input.hasPrefix("tile ") || input.hasPrefix("snap ")) && input.hasSuffix(" right") {
            let prefix = input.hasPrefix("tile ") ? "tile " : "snap "
            let appName = String(input.dropFirst(prefix.count).dropLast(" right".count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && appName != "window" {
                return try? await TileWindowRightTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- Tile top left (quarter) ---
        if input == "tile top left" || input == "snap top left" || input == "quarter top left" ||
           input == "top left" || input == "top left quarter" || input == "top-left" ||
           input == "move window top left" || input == "window to top left" ||
           matches(words, required: ["tile", "top", "left"]) || matches(words, required: ["snap", "top", "left"]) ||
           matches(words, required: ["quarter", "top", "left"]) {
            return try? await TileWindowTopLeftTool().execute(arguments: "{}")
        }
        // "tile [app] top left"
        if input.hasPrefix("tile ") && input.hasSuffix(" top left") && input != "tile top left" {
            let appName = String(input.dropFirst("tile ".count).dropLast(" top left".count)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && appName != "window" {
                return try? await TileWindowTopLeftTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        // --- List windows ---
        if input == "list windows" || input == "show windows" || input == "open windows" ||
           input == "what windows are open" || input == "which windows are open" ||
           input == "show all windows" || input == "list all windows" || input == "show open windows" ||
           matches(words, required: ["list", "windows"]) || matches(words, required: ["show", "windows"]) {
            return try? await ListWindowsTool().execute(arguments: "{}")
        }

        // --- Side by side ---
        // "tile [app1] and [app2] side by side" / "put [app1] and [app2] side by side"
        // "split screen [app1] and [app2]" / "[app1] and [app2] side by side"
        if input.contains("side by side") || (matches(words, required: ["split", "screen"]) && input.contains(" and ")) {
            if let (left, right) = extractSideBySideApps(input) {
                let jsonArg = "{\"left_app\": \"\(escapeJSON(left))\", \"right_app\": \"\(escapeJSON(right))\"}"
                return try? await TileWindowsSideBySideTool().execute(arguments: jsonArg)
            }
        }

        // --- Arrange windows ---
        if input == "arrange windows" || input == "auto arrange windows" || input == "organize windows" ||
           matches(words, required: ["arrange", "windows"]) {
            return try? await ArrangeWindowsTool().execute(arguments: "{\"layout\": \"grid\"}")
        }
        if input == "grid layout" || input == "grid windows" || matches(words, required: ["grid", "layout"]) ||
           matches(words, required: ["grid", "windows"]) {
            return try? await ArrangeWindowsTool().execute(arguments: "{\"layout\": \"grid\"}")
        }
        if input == "stack windows" || input == "stack layout" || matches(words, required: ["stack", "windows"]) ||
           matches(words, required: ["stack", "layout"]) {
            return try? await ArrangeWindowsTool().execute(arguments: "{\"layout\": \"stack\"}")
        }
        if input == "cascade windows" || input == "cascade layout" || matches(words, required: ["cascade", "windows"]) ||
           matches(words, required: ["cascade", "layout"]) {
            return try? await ArrangeWindowsTool().execute(arguments: "{\"layout\": \"cascade\"}")
        }

        return nil
    }

    // MARK: - Side-by-side app extraction

    /// Extracts two app names from phrases like:
    /// - "tile safari and chrome side by side"
    /// - "put X and Y side by side"
    /// - "split screen X and Y"
    /// - "X and Y side by side"
    private func extractSideBySideApps(_ input: String) -> (String, String)? {
        var cleaned = input

        // Remove common framing phrases
        let removals = ["tile ", "put ", "snap ", "place ", "set ", "move ",
                        " side by side", "split screen ", "split-screen "]
        for r in removals {
            cleaned = cleaned.replacingOccurrences(of: r, with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // Split on " and "
        let parts = cleaned.components(separatedBy: " and ")
        guard parts.count == 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }
}
