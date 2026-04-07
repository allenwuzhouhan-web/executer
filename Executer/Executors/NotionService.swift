import Foundation

// MARK: - Notion API Key Management

enum NotionKeyStore {
    private static let keychainKey = "notion_api_token"

    static func getToken() -> String? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        _ = KeychainHelper.save(key: keychainKey, data: data)
    }

    static func hasToken() -> Bool { getToken() != nil }

    static func deleteToken() { KeychainHelper.delete(key: keychainKey) }
}

// MARK: - Errors

enum NotionError: LocalizedError {
    case noToken
    case unauthorized
    case invalidURL
    case parseError
    case apiError(status: Int, message: String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No Notion API token configured. Use the notion_setup tool to set your integration token."
        case .unauthorized:
            return "Notion API token is invalid or expired. Use notion_setup to set a new token."
        case .invalidURL:
            return "Invalid Notion API URL."
        case .parseError:
            return "Failed to parse Notion API response."
        case .apiError(let status, let message):
            // Extract just the message from Notion's JSON error response
            if let data = message.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                return "Notion API error (\(status)): \(msg)"
            }
            return "Notion API error (\(status)): \(message)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }
}

// MARK: - Notion API Client

actor NotionAPI {
    static let shared = NotionAPI()
    private let apiVersion = "2022-06-28"
    private let baseURL = "https://api.notion.com/v1"

    func request(_ method: String, path: String, body: [String: Any]? = nil, query: [String: String]? = nil) async throws -> [String: Any] {
        guard let token = NotionKeyStore.getToken() else {
            throw NotionError.noToken
        }

        var urlStr = "\(baseURL)\(path)"
        if let query = query, !query.isEmpty {
            let params = query.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
            }
            urlStr += "?" + params.joined(separator: "&")
        }

        guard let url = URL(string: urlStr) else { throw NotionError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await PinnedURLSession.shared.session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw NotionError.networkError("Invalid response")
        }

        if http.statusCode == 401 { throw NotionError.unauthorized }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.apiError(status: http.statusCode, message: msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.parseError
        }
        return json
    }

    // MARK: - Search

    func search(query: String, filter: String? = nil, pageSize: Int = 10) async throws -> [String: Any] {
        var body: [String: Any] = ["query": query, "page_size": pageSize]
        if let filter = filter {
            body["filter"] = ["value": filter, "property": "object"]
        }
        return try await request("POST", path: "/search", body: body)
    }

    // MARK: - Pages

    func getPage(id: String) async throws -> [String: Any] {
        try await request("GET", path: "/pages/\(id.notionIDCleaned)")
    }

    func createPage(parent: [String: Any], properties: [String: Any],
                    children: [[String: Any]]? = nil, icon: String? = nil, cover: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["parent": parent, "properties": properties]
        if let children = children { body["children"] = children }
        if let icon = icon { body["icon"] = ["type": "emoji", "emoji": icon] as [String: Any] }
        if let cover = cover { body["cover"] = ["type": "external", "external": ["url": cover]] as [String: Any] }
        return try await request("POST", path: "/pages", body: body)
    }

    func updatePage(id: String, properties: [String: Any]? = nil,
                    icon: String? = nil, cover: String? = nil, archived: Bool? = nil) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let properties = properties { body["properties"] = properties }
        if let icon = icon { body["icon"] = ["type": "emoji", "emoji": icon] as [String: Any] }
        if let cover = cover { body["cover"] = ["type": "external", "external": ["url": cover]] as [String: Any] }
        if let archived = archived { body["archived"] = archived }
        return try await request("PATCH", path: "/pages/\(id.notionIDCleaned)", body: body)
    }

    // MARK: - Blocks

    func getBlockChildren(blockId: String, startCursor: String? = nil, pageSize: Int = 100) async throws -> [String: Any] {
        var query: [String: String] = ["page_size": "\(pageSize)"]
        if let cursor = startCursor { query["start_cursor"] = cursor }
        return try await request("GET", path: "/blocks/\(blockId.notionIDCleaned)/children", query: query)
    }

    /// Fetches ALL block children by paginating through the API.
    func getAllBlockChildren(blockId: String) async throws -> [[String: Any]] {
        var allBlocks: [[String: Any]] = []
        var cursor: String? = nil

        repeat {
            let result = try await getBlockChildren(blockId: blockId, startCursor: cursor)
            if let blocks = result["results"] as? [[String: Any]] {
                allBlocks.append(contentsOf: blocks)
            }
            cursor = result["next_cursor"] as? String
        } while cursor != nil

        return allBlocks
    }

    func appendBlocks(blockId: String, children: [[String: Any]]) async throws -> [String: Any] {
        try await request("PATCH", path: "/blocks/\(blockId.notionIDCleaned)/children", body: ["children": children])
    }

    // MARK: - Databases

    func getDatabase(id: String) async throws -> [String: Any] {
        try await request("GET", path: "/databases/\(id.notionIDCleaned)")
    }

    func queryDatabase(id: String, filter: [String: Any]? = nil,
                       sorts: [[String: Any]]? = nil, pageSize: Int = 20) async throws -> [String: Any] {
        var body: [String: Any] = ["page_size": pageSize]
        if let filter = filter { body["filter"] = filter }
        if let sorts = sorts { body["sorts"] = sorts }
        return try await request("POST", path: "/databases/\(id.notionIDCleaned)/query", body: body)
    }

    func createDatabase(parentPageId: String, title: String,
                        properties: [String: Any]) async throws -> [String: Any] {
        try await request("POST", path: "/databases", body: [
            "parent": ["type": "page_id", "page_id": parentPageId.notionIDCleaned] as [String: Any],
            "title": [["type": "text", "text": ["content": title]]] as [[String: Any]],
            "properties": properties
        ])
    }

    // MARK: - Comments

    func createComment(pageId: String, richText: [[String: Any]]) async throws -> [String: Any] {
        try await request("POST", path: "/comments", body: [
            "parent": ["page_id": pageId.notionIDCleaned] as [String: Any],
            "rich_text": richText
        ])
    }

    func getComments(blockId: String, pageSize: Int = 20) async throws -> [String: Any] {
        try await request("GET", path: "/comments", query: [
            "block_id": blockId.notionIDCleaned,
            "page_size": "\(pageSize)"
        ])
    }

    // MARK: - Users

    func getMe() async throws -> [String: Any] {
        try await request("GET", path: "/users/me")
    }
}

// MARK: - Notion ID Helpers

extension String {
    /// Strips dashes and URL prefixes from Notion IDs.
    /// Accepts: raw UUID, dashed UUID, or full Notion URL.
    var notionIDCleaned: String {
        var id = self
        // Strip Notion URL prefix
        if id.contains("notion.so") || id.contains("notion.site") {
            id = id.components(separatedBy: "/").last ?? id
            id = id.components(separatedBy: "-").last ?? id
            id = id.components(separatedBy: "?").first ?? id
        }
        // Remove dashes from UUID format
        id = id.replacingOccurrences(of: "-", with: "")
        // Validate: should be 32 hex chars
        if id.count == 32, id.allSatisfy({ $0.isHexDigit }) {
            return id
        }
        // Return as-is if it doesn't look like a UUID (might be a short ID)
        return self.replacingOccurrences(of: "-", with: "")
    }
}

// MARK: - Markdown → Notion Blocks

enum NotionBlockBuilder {

    /// Convert a markdown string to an array of Notion block objects.
    static func markdownToBlocks(_ markdown: String) -> [[String: Any]] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [[String: Any]] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line → skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Divider
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(["object": "block", "type": "divider", "divider": [:] as [String: Any]])
                i += 1
                continue
            }

            // Code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                let codeText = codeLines.joined(separator: "\n")
                blocks.append([
                    "object": "block",
                    "type": "code",
                    "code": [
                        "rich_text": plainRichText(codeText),
                        "language": lang.isEmpty ? "plain text" : lang
                    ] as [String: Any]
                ])
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                blocks.append(headingBlock(text, level: 3))
                i += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                blocks.append(headingBlock(text, level: 2))
                i += 1
                continue
            }
            if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append(headingBlock(text, level: 1))
                i += 1
                continue
            }

            // To-do items
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [ ] ") {
                let checked = trimmed.hasPrefix("- [x]")
                let text = String(trimmed.dropFirst(6))
                blocks.append([
                    "object": "block",
                    "type": "to_do",
                    "to_do": [
                        "rich_text": parseInlineMarkdown(text),
                        "checked": checked
                    ] as [String: Any]
                ])
                i += 1
                continue
            }

            // Bulleted list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": ["rich_text": parseInlineMarkdown(text)]
                ])
                i += 1
                continue
            }

            // Numbered list
            if let dotRange = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let text = String(trimmed[dotRange.upperBound...])
                blocks.append([
                    "object": "block",
                    "type": "numbered_list_item",
                    "numbered_list_item": ["rich_text": parseInlineMarkdown(text)]
                ])
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append([
                    "object": "block",
                    "type": "quote",
                    "quote": ["rich_text": parseInlineMarkdown(text)]
                ])
                i += 1
                continue
            }

            // Callout (special: > emoji text)
            if trimmed.hasPrefix("> ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append([
                    "object": "block",
                    "type": "quote",
                    "quote": ["rich_text": parseInlineMarkdown(content)]
                ])
                i += 1
                continue
            }

            // Image: ![alt](url)
            if let match = trimmed.range(of: #"^!\[.*?\]\((.*?)\)$"#, options: .regularExpression) {
                let urlStart = trimmed.range(of: "(", range: match)!.upperBound
                let urlEnd = trimmed.index(before: trimmed[match].endIndex)
                let imageURL = String(trimmed[urlStart..<urlEnd])
                blocks.append([
                    "object": "block",
                    "type": "image",
                    "image": [
                        "type": "external",
                        "external": ["url": imageURL]
                    ] as [String: Any]
                ])
                i += 1
                continue
            }

            // Table (simple markdown table)
            if trimmed.contains("|") && trimmed.hasPrefix("|") {
                var tableLines: [String] = [trimmed]
                i += 1
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    if tl.contains("|") {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }
                if let table = parseMarkdownTable(tableLines) {
                    blocks.append(table)
                }
                continue
            }

            // Default: paragraph
            blocks.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": parseInlineMarkdown(trimmed)]
            ])
            i += 1
        }

        return blocks
    }

    // MARK: - Inline Markdown → Rich Text

    /// Parse inline markdown (bold, italic, code, links, strikethrough) into Notion rich_text array.
    static func parseInlineMarkdown(_ text: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            // Bold + Italic: ***text***
            if remaining.hasPrefix("***"),
               let end = remaining.dropFirst(3).range(of: "***") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 3)..<end.lowerBound])
                result.append(richTextSegment(content, bold: true, italic: true))
                remaining = remaining[end.upperBound...]
                continue
            }

            // Bold: **text**
            if remaining.hasPrefix("**"),
               let end = remaining.dropFirst(2).range(of: "**") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                result.append(richTextSegment(content, bold: true))
                remaining = remaining[end.upperBound...]
                continue
            }

            // Italic: *text*
            if remaining.hasPrefix("*"),
               let end = remaining.dropFirst(1).range(of: "*") {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                result.append(richTextSegment(content, italic: true))
                remaining = remaining[end.upperBound...]
                continue
            }

            // Strikethrough: ~~text~~
            if remaining.hasPrefix("~~"),
               let end = remaining.dropFirst(2).range(of: "~~") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                result.append(richTextSegment(content, strikethrough: true))
                remaining = remaining[end.upperBound...]
                continue
            }

            // Inline code: `text`
            if remaining.hasPrefix("`"),
               let end = remaining.dropFirst(1).range(of: "`") {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                result.append(richTextSegment(content, code: true))
                remaining = remaining[end.upperBound...]
                continue
            }

            // Link: [text](url)
            if remaining.hasPrefix("["),
               let closeBracket = remaining.range(of: "]("),
               let closeParen = remaining[closeBracket.upperBound...].range(of: ")") {
                let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket.lowerBound])
                let linkURL = String(remaining[closeBracket.upperBound..<closeParen.lowerBound])
                result.append(richTextSegment(linkText, link: linkURL))
                remaining = remaining[closeParen.upperBound...]
                continue
            }

            // Plain text: consume until next special char
            let specialChars: [Character] = ["*", "~", "`", "["]
            var endIdx = remaining.index(after: remaining.startIndex)
            while endIdx < remaining.endIndex && !specialChars.contains(remaining[endIdx]) {
                endIdx = remaining.index(after: endIdx)
            }
            let plain = String(remaining[remaining.startIndex..<endIdx])
            if !plain.isEmpty {
                result.append(richTextSegment(plain))
            }
            remaining = remaining[endIdx...]
        }

        return result.isEmpty ? plainRichText(text) : result
    }

    // MARK: - Rich Text Segment Builders

    static func richTextSegment(_ content: String, bold: Bool = false, italic: Bool = false,
                                strikethrough: Bool = false, code: Bool = false,
                                link: String? = nil) -> [String: Any] {
        var annotations: [String: Any] = [:]
        if bold { annotations["bold"] = true }
        if italic { annotations["italic"] = true }
        if strikethrough { annotations["strikethrough"] = true }
        if code { annotations["code"] = true }

        var textObj: [String: Any] = ["content": content]
        if let link = link { textObj["link"] = ["url": link] }

        var segment: [String: Any] = [
            "type": "text",
            "text": textObj
        ]
        if !annotations.isEmpty { segment["annotations"] = annotations }
        return segment
    }

    static func plainRichText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text]]]
    }

    private static func headingBlock(_ text: String, level: Int) -> [String: Any] {
        let key: String
        switch level {
        case 1: key = "heading_1"
        case 2: key = "heading_2"
        default: key = "heading_3"
        }
        return [
            "object": "block",
            "type": key,
            key: ["rich_text": parseInlineMarkdown(text)]
        ]
    }

    // MARK: - Table Parsing

    private static func parseMarkdownTable(_ lines: [String]) -> [String: Any]? {
        guard lines.count >= 2 else { return nil }

        // Parse rows, skipping separator row (|---|---|)
        var rows: [[String]] = []
        for line in lines {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Skip separator row
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) }) { continue }
            if !cells.isEmpty { rows.append(cells) }
        }

        guard !rows.isEmpty else { return nil }
        let width = rows.map(\.count).max() ?? 1

        let tableRows: [[String: Any]] = rows.enumerated().map { _, row in
            let cells: [[String: Any]] = (0..<width).map { col in
                let text = col < row.count ? row[col] : ""
                return ["type": "text", "text": ["content": text]] as [String: Any]
            }
            // Each cell is wrapped as an array of rich_text
            return [
                "type": "table_row",
                "table_row": ["cells": cells.map { [$0] }]
            ]
        }

        return [
            "object": "block",
            "type": "table",
            "table": [
                "table_width": width,
                "has_column_header": true,
                "has_row_header": false,
                "children": tableRows
            ] as [String: Any]
        ]
    }
}

// MARK: - Notion Blocks → Markdown

enum NotionBlockReader {

    /// Convert an array of Notion block objects into readable markdown.
    static func blocksToMarkdown(_ blocks: [[String: Any]], indent: String = "") -> String {
        var lines: [String] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            let data = block[type] as? [String: Any] ?? [:]

            switch type {
            case "paragraph":
                let text = extractRichText(data["rich_text"])
                if !text.isEmpty { lines.append("\(indent)\(text)") }
                else { lines.append("") }

            case "heading_1":
                lines.append("\(indent)# \(extractRichText(data["rich_text"]))")
            case "heading_2":
                lines.append("\(indent)## \(extractRichText(data["rich_text"]))")
            case "heading_3":
                lines.append("\(indent)### \(extractRichText(data["rich_text"]))")

            case "bulleted_list_item":
                lines.append("\(indent)- \(extractRichText(data["rich_text"]))")
            case "numbered_list_item":
                lines.append("\(indent)1. \(extractRichText(data["rich_text"]))")

            case "to_do":
                let checked = data["checked"] as? Bool ?? false
                let marker = checked ? "[x]" : "[ ]"
                lines.append("\(indent)- \(marker) \(extractRichText(data["rich_text"]))")

            case "code":
                let lang = data["language"] as? String ?? ""
                let code = extractPlainText(data["rich_text"])
                lines.append("\(indent)```\(lang)")
                lines.append(code)
                lines.append("\(indent)```")

            case "quote":
                let text = extractRichText(data["rich_text"])
                for quoteLine in text.components(separatedBy: "\n") {
                    lines.append("\(indent)> \(quoteLine)")
                }

            case "callout":
                let icon = (block["callout"] as? [String: Any])?["icon"] as? [String: Any]
                let emoji = icon?["emoji"] as? String ?? ""
                let text = extractRichText(data["rich_text"])
                lines.append("\(indent)> \(emoji) \(text)")

            case "divider":
                lines.append("\(indent)---")

            case "image":
                let url = extractImageURL(data)
                let caption = extractPlainText(data["caption"])
                lines.append("\(indent)![\(caption)](\(url))")

            case "bookmark":
                let url = data["url"] as? String ?? ""
                let caption = extractPlainText(data["caption"])
                lines.append("\(indent)[\(caption.isEmpty ? url : caption)](\(url))")

            case "toggle":
                let text = extractRichText(data["rich_text"])
                lines.append("\(indent)<details><summary>\(text)</summary>")
                // Toggle children would need recursive fetch
                lines.append("\(indent)</details>")

            case "table":
                if let tableRows = data["children"] as? [[String: Any]] {
                    lines.append(contentsOf: renderTable(tableRows, indent: indent))
                }

            case "column_list", "synced_block":
                // Container blocks — children handled separately
                break

            case "child_page":
                let title = data["title"] as? String ?? "Untitled"
                lines.append("\(indent)> **Linked page:** \(title)")

            case "child_database":
                let title = data["title"] as? String ?? "Untitled"
                lines.append("\(indent)> **Linked database:** \(title)")

            case "embed":
                let url = data["url"] as? String ?? ""
                lines.append("\(indent)[Embed](\(url))")

            case "video":
                let url = extractMediaURL(data)
                lines.append("\(indent)[Video](\(url))")

            case "file":
                let url = extractMediaURL(data)
                lines.append("\(indent)[File](\(url))")

            case "pdf":
                let url = extractMediaURL(data)
                lines.append("\(indent)[PDF](\(url))")

            case "equation":
                let expression = data["expression"] as? String ?? ""
                lines.append("\(indent)$$\(expression)$$")

            default:
                // Unknown block type — try to extract any text
                let text = extractRichText(data["rich_text"])
                if !text.isEmpty { lines.append("\(indent)\(text)") }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Rich Text Extraction

    /// Extract rich text with markdown formatting (bold, italic, etc.)
    static func extractRichText(_ richTextAny: Any?) -> String {
        guard let richText = richTextAny as? [[String: Any]] else { return "" }
        return richText.map { segment -> String in
            let text = (segment["text"] as? [String: Any])?["content"] as? String
                ?? segment["plain_text"] as? String
                ?? ""
            let annotations = segment["annotations"] as? [String: Any] ?? [:]
            let link = (segment["text"] as? [String: Any])?["link"] as? [String: Any]

            var result = text
            if annotations["code"] as? Bool == true { result = "`\(result)`" }
            if annotations["bold"] as? Bool == true { result = "**\(result)**" }
            if annotations["italic"] as? Bool == true { result = "*\(result)*" }
            if annotations["strikethrough"] as? Bool == true { result = "~~\(result)~~" }
            if let url = link?["url"] as? String { result = "[\(result)](\(url))" }

            return result
        }.joined()
    }

    /// Extract plain text only (no markdown formatting).
    static func extractPlainText(_ richTextAny: Any?) -> String {
        guard let richText = richTextAny as? [[String: Any]] else { return "" }
        return richText.compactMap { segment in
            (segment["text"] as? [String: Any])?["content"] as? String
                ?? segment["plain_text"] as? String
        }.joined()
    }

    private static func extractImageURL(_ data: [String: Any]) -> String {
        if let ext = data["external"] as? [String: Any] { return ext["url"] as? String ?? "" }
        if let file = data["file"] as? [String: Any] { return file["url"] as? String ?? "" }
        return ""
    }

    private static func extractMediaURL(_ data: [String: Any]) -> String {
        if let ext = data["external"] as? [String: Any] { return ext["url"] as? String ?? "" }
        if let file = data["file"] as? [String: Any] { return file["url"] as? String ?? "" }
        return data["url"] as? String ?? ""
    }

    private static func renderTable(_ rows: [[String: Any]], indent: String) -> [String] {
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            guard let cells = (row["table_row"] as? [String: Any])?["cells"] as? [[[String: Any]]] else { continue }
            let cellTexts = cells.map { extractPlainText($0) }
            lines.append("\(indent)| \(cellTexts.joined(separator: " | ")) |")
            if i == 0 {
                lines.append("\(indent)| \(cellTexts.map { _ in "---" }.joined(separator: " | ")) |")
            }
        }
        return lines
    }
}

// MARK: - Property Formatting Helpers

enum NotionPropertyFormatter {

    /// Format page properties into a readable string.
    static func formatProperties(_ properties: [String: Any]) -> String {
        var lines: [String] = []
        for (name, propAny) in properties.sorted(by: { $0.key < $1.key }) {
            guard let prop = propAny as? [String: Any],
                  let type = prop["type"] as? String else { continue }
            let value = extractPropertyValue(prop, type: type)
            if !value.isEmpty { lines.append("- **\(name)**: \(value)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Extract the display value from a Notion property.
    static func extractPropertyValue(_ prop: [String: Any], type: String) -> String {
        switch type {
        case "title":
            return NotionBlockReader.extractPlainText(prop["title"])
        case "rich_text":
            return NotionBlockReader.extractPlainText(prop["rich_text"])
        case "number":
            if let num = prop["number"] as? NSNumber { return num.stringValue }
            return ""
        case "select":
            return (prop["select"] as? [String: Any])?["name"] as? String ?? ""
        case "multi_select":
            let items = prop["multi_select"] as? [[String: Any]] ?? []
            return items.compactMap { $0["name"] as? String }.joined(separator: ", ")
        case "status":
            return (prop["status"] as? [String: Any])?["name"] as? String ?? ""
        case "date":
            if let date = prop["date"] as? [String: Any] {
                let start = date["start"] as? String ?? ""
                let end = date["end"] as? String
                return end != nil ? "\(start) → \(end!)" : start
            }
            return ""
        case "checkbox":
            return (prop["checkbox"] as? Bool) == true ? "Yes" : "No"
        case "url":
            return prop["url"] as? String ?? ""
        case "email":
            return prop["email"] as? String ?? ""
        case "phone_number":
            return prop["phone_number"] as? String ?? ""
        case "formula":
            if let formula = prop["formula"] as? [String: Any] {
                let fType = formula["type"] as? String ?? ""
                return formula[fType] as? String ?? "\(formula[fType] ?? "")"
            }
            return ""
        case "relation":
            let relations = prop["relation"] as? [[String: Any]] ?? []
            return relations.compactMap { $0["id"] as? String }.joined(separator: ", ")
        case "rollup":
            if let rollup = prop["rollup"] as? [String: Any] {
                let rType = rollup["type"] as? String ?? ""
                if rType == "number" { return "\(rollup["number"] ?? "")" }
                if rType == "array", let arr = rollup["array"] as? [[String: Any]] {
                    return arr.compactMap { item -> String? in
                        let t = item["type"] as? String ?? ""
                        return extractPropertyValue(item, type: t)
                    }.joined(separator: ", ")
                }
            }
            return ""
        case "people":
            let people = prop["people"] as? [[String: Any]] ?? []
            return people.compactMap { $0["name"] as? String }.joined(separator: ", ")
        case "files":
            let files = prop["files"] as? [[String: Any]] ?? []
            return files.compactMap { file -> String? in
                if let ext = file["external"] as? [String: Any] { return ext["url"] as? String }
                if let f = file["file"] as? [String: Any] { return f["url"] as? String }
                return file["name"] as? String
            }.joined(separator: ", ")
        case "created_time":
            return prop["created_time"] as? String ?? ""
        case "last_edited_time":
            return prop["last_edited_time"] as? String ?? ""
        case "created_by", "last_edited_by":
            return (prop[type] as? [String: Any])?["name"] as? String ?? ""
        case "unique_id":
            if let uid = prop["unique_id"] as? [String: Any] {
                let prefix = uid["prefix"] as? String ?? ""
                let number = uid["number"] as? Int ?? 0
                return "\(prefix)\(number)"
            }
            return ""
        default:
            return ""
        }
    }

    /// Build a Notion property value for database entry creation.
    static func buildPropertyValue(type: String, value: Any) -> [String: Any]? {
        switch type {
        case "title":
            guard let str = value as? String else { return nil }
            return ["title": [["text": ["content": str]]]]
        case "rich_text":
            guard let str = value as? String else { return nil }
            return ["rich_text": [["text": ["content": str]]]]
        case "number":
            if let num = value as? Double { return ["number": num] }
            if let num = value as? Int { return ["number": num] }
            if let str = value as? String, let num = Double(str) { return ["number": num] }
            return nil
        case "select":
            guard let str = value as? String else { return nil }
            return ["select": ["name": str]]
        case "multi_select":
            if let arr = value as? [String] {
                return ["multi_select": arr.map { ["name": $0] }]
            }
            if let str = value as? String {
                let items = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return ["multi_select": items.map { ["name": $0] }]
            }
            return nil
        case "status":
            guard let str = value as? String else { return nil }
            return ["status": ["name": str]]
        case "date":
            if let str = value as? String {
                return ["date": ["start": str]]
            }
            if let dict = value as? [String: Any] {
                return ["date": dict]
            }
            return nil
        case "checkbox":
            if let b = value as? Bool { return ["checkbox": b] }
            if let str = value as? String { return ["checkbox": str.lowercased() == "true" || str == "1"] }
            return nil
        case "url":
            guard let str = value as? String else { return nil }
            return ["url": str]
        case "email":
            guard let str = value as? String else { return nil }
            return ["email": str]
        case "phone_number":
            guard let str = value as? String else { return nil }
            return ["phone_number": str]
        default:
            return nil
        }
    }
}
