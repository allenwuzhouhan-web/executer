import Foundation

extension LocalCommandRouter {

    func tryAppCommand(_ input: String) async -> String? {
        let prefixes = [
            ("open ", "launch"), ("launch ", "launch"), ("start ", "launch"),
            ("quit ", "quit"), ("close ", "quit"), ("kill ", "quit"),
            ("switch to ", "switch"), ("go to ", "switch"), ("bring up ", "switch"),
        ]
        for (prefix, action) in prefixes {
            if input.hasPrefix(prefix) {
                let appName = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !appName.isEmpty else { continue }
                // Don't intercept ambiguous commands like "open the file..." or web navigation
                let nonAppWords = ["file", "files", "folder", "window", "tab", "url", "link", "page", "document",
                                   "youtube", "google", "safari", "http", "www", "website", ".com", ".org", ".net"]
                if nonAppWords.contains(where: { appName.lowercased().contains($0) }) {
                    return nil
                }
                let jsonArg = "{\"app_name\": \"\(escapeJSON(appName))\"}"
                switch action {
                case "launch":
                    return try? await LaunchAppTool().execute(arguments: jsonArg)
                case "quit":
                    return try? await QuitAppTool().execute(arguments: jsonArg)
                case "switch":
                    return try? await SwitchToAppTool().execute(arguments: jsonArg)
                default:
                    break
                }
            }
        }

        // "hide [app]"
        if input.hasPrefix("hide ") {
            let appName = String(input.dropFirst("hide ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !appName.isEmpty && appName != "all windows" {
                return try? await HideAppTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        return nil
    }
}
