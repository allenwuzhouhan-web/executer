import Foundation

// MARK: - Step 2: Clipboard History Tools

struct GetClipboardHistoryTool: ToolDefinition {
    let name = "get_clipboard_history"
    let description = "Get recent clipboard history entries"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "limit": JSONSchema.integer(description: "Maximum number of entries to return (default 20)", minimum: 1, maximum: 100),
            "minutes_ago": JSONSchema.integer(description: "Only return entries from the last N minutes", minimum: 1, maximum: nil)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let limit = optionalInt("limit", from: args) ?? 20
        let minutesAgo = optionalInt("minutes_ago", from: args)

        let entries = ClipboardHistoryManager.shared.getHistory(limit: limit, minutesAgo: minutesAgo)
        if entries.isEmpty {
            return "No clipboard history entries found."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let lines = entries.map { entry -> String in
            let time = formatter.string(from: entry.timestamp)
            let preview = entry.text.prefix(100)
            let truncated = preview.count < entry.text.count ? "\(preview)..." : String(preview)
            let app = entry.sourceApp.map { " [\($0)]" } ?? ""
            return "[\(time)]\(app) \(truncated)"
        }

        return "Clipboard history (\(entries.count) entries):\n\(lines.joined(separator: "\n"))"
    }
}

struct SearchClipboardHistoryTool: ToolDefinition {
    let name = "search_clipboard_history"
    let description = "Search clipboard history for text matching a query"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Text to search for (case-insensitive)"),
            "limit": JSONSchema.integer(description: "Maximum number of results (default 10)", minimum: 1, maximum: 50)
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 10

        let entries = ClipboardHistoryManager.shared.search(query: query, limit: limit)
        if entries.isEmpty {
            return "No clipboard entries matching '\(query)'."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let lines = entries.map { entry -> String in
            let time = formatter.string(from: entry.timestamp)
            let preview = entry.text.prefix(100)
            let truncated = preview.count < entry.text.count ? "\(preview)..." : String(preview)
            return "[\(time)] \(truncated)"
        }

        return "Found \(entries.count) matches for '\(query)':\n\(lines.joined(separator: "\n"))"
    }
}

struct ClearClipboardHistoryTool: ToolDefinition {
    let name = "clear_clipboard_history"
    let description = "Clear all clipboard history entries"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        ClipboardHistoryManager.shared.clearAll()
        return "Clipboard history cleared."
    }
}
