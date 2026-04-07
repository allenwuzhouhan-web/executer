import Foundation

// MARK: - Setup

struct NotionSetupTool: ToolDefinition {
    let name = "notion_setup"
    let description = "Configure the Notion integration token. Create an internal integration at https://www.notion.so/profile/integrations and paste the token here. After setup, share pages/databases with your integration via the '...' menu → 'Connect to' in Notion."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "token": JSONSchema.string(description: "Notion internal integration token (starts with ntn_ or secret_)")
        ], required: ["token"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let token = try requiredString("token", from: args)

        guard token.hasPrefix("ntn_") || token.hasPrefix("secret_") else {
            return "Invalid token format. Notion tokens start with 'ntn_' or 'secret_'. Create one at https://www.notion.so/profile/integrations"
        }

        NotionKeyStore.setToken(token)

        // Test the connection
        do {
            let me = try await NotionAPI.shared.getMe()
            let botName = (me["bot"] as? [String: Any])?["owner"] as? [String: Any]
            let name = botName?["name"] as? String
                ?? (me["name"] as? String)
                ?? "Notion Integration"
            return "Notion connected as '\(name)'. Now share pages with this integration in Notion (page '...' menu → Connect to)."
        } catch {
            NotionKeyStore.deleteToken()
            return "Token saved but connection test failed: \(error.localizedDescription). Please check the token."
        }
    }
}

// MARK: - Search

struct NotionSearchTool: ToolDefinition {
    let name = "notion_search"
    let description = "Search your Notion workspace for pages and databases. Returns titles, IDs, and last edited times."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query text"),
            "filter": JSONSchema.enumString(description: "Filter results by type", values: ["page", "database"]),
            "limit": JSONSchema.integer(description: "Max results (default 10, max 100)", minimum: 1, maximum: 100)
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let filter = optionalString("filter", from: args)
        let limit = optionalInt("limit", from: args) ?? 10

        let result = try await NotionAPI.shared.search(query: query, filter: filter, pageSize: limit)
        guard let results = result["results"] as? [[String: Any]], !results.isEmpty else {
            return "No results found for '\(query)'."
        }

        var lines: [String] = ["Found \(results.count) result(s):"]
        for item in results {
            let id = item["id"] as? String ?? ""
            let type = item["object"] as? String ?? ""
            let lastEdited = item["last_edited_time"] as? String ?? ""
            let title = extractTitle(from: item)
            let icon = extractIcon(from: item)

            lines.append("")
            lines.append("\(icon) **\(title)** (\(type))")
            lines.append("  ID: `\(id)`")
            if !lastEdited.isEmpty {
                lines.append("  Last edited: \(formatDate(lastEdited))")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Read Page

struct NotionReadPageTool: ToolDefinition {
    let name = "notion_read_page"
    let description = "Read a Notion page's content, including its properties and all content blocks rendered as markdown."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "page_id": JSONSchema.string(description: "The page ID (UUID, dashed UUID, or Notion URL)")
        ], required: ["page_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pageId = try requiredString("page_id", from: args)

        // Fetch page metadata and blocks in parallel
        async let pageResult = NotionAPI.shared.getPage(id: pageId)
        async let blocksResult = NotionAPI.shared.getAllBlockChildren(blockId: pageId)

        let page = try await pageResult
        let blocks = try await blocksResult

        let title = extractTitle(from: page)
        let icon = extractIcon(from: page)

        var lines: [String] = ["\(icon) **\(title)**"]

        // Properties
        if let properties = page["properties"] as? [String: Any] {
            let propsStr = NotionPropertyFormatter.formatProperties(properties)
            if !propsStr.isEmpty {
                lines.append("")
                lines.append("**Properties:**")
                lines.append(propsStr)
            }
        }

        // Content blocks
        if !blocks.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append(NotionBlockReader.blocksToMarkdown(blocks))
        } else {
            lines.append("")
            lines.append("*(Page has no content blocks)*")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Create Page

struct NotionCreatePageTool: ToolDefinition {
    let name = "notion_create_page"
    let description = """
    Create a new page in Notion with rich content. Write content in markdown — it will be converted to \
    Notion blocks (headings, bullets, numbered lists, code blocks, quotes, tables, to-dos, images, dividers). \
    Supports inline formatting: **bold**, *italic*, ~~strikethrough~~, `code`, [links](url).
    """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "parent_id": JSONSchema.string(description: "Parent page ID or database ID where the new page will be created"),
            "title": JSONSchema.string(description: "Page title"),
            "content": JSONSchema.string(description: "Page content in markdown format. Supports headings, bullets, numbered lists, code blocks, quotes, tables, to-dos, images, and dividers."),
            "parent_type": JSONSchema.enumString(description: "Type of parent (default: auto-detect)", values: ["page", "database"]),
            "icon": JSONSchema.string(description: "Page icon as emoji (e.g. '🚀')"),
            "cover_url": JSONSchema.string(description: "Cover image URL"),
            "properties": JSONSchema.string(description: "JSON object of database properties (when parent is a database). Keys are property names, values are property values.")
        ], required: ["parent_id", "title"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let parentId = try requiredString("parent_id", from: args)
        let title = try requiredString("title", from: args)
        let content = optionalString("content", from: args)
        let parentType = optionalString("parent_type", from: args)
        let icon = optionalString("icon", from: args)
        let coverUrl = optionalString("cover_url", from: args)
        let propertiesJSON = optionalString("properties", from: args)

        // Determine parent type
        let isDatabase: Bool
        if let pt = parentType {
            isDatabase = pt == "database"
        } else {
            // Auto-detect: try database first, fall back to page
            isDatabase = await detectIsDatabase(parentId)
        }

        let parent: [String: Any]
        if isDatabase {
            parent = ["database_id": parentId.notionIDCleaned]
        } else {
            parent = ["page_id": parentId.notionIDCleaned]
        }

        // Build properties
        var properties: [String: Any]
        if isDatabase, let propsJSON = propertiesJSON,
           let propsData = propsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] {
            // For database pages, we need to build proper property values
            properties = try await buildDatabaseProperties(databaseId: parentId, title: title, rawProperties: parsed)
        } else {
            properties = ["title": [["text": ["content": title]]] as [[String: Any]]]
        }

        // Convert markdown content to blocks
        var children: [[String: Any]]? = nil
        if let content = content, !content.isEmpty {
            children = NotionBlockBuilder.markdownToBlocks(content)
        }

        let result = try await NotionAPI.shared.createPage(
            parent: parent,
            properties: properties,
            children: children,
            icon: icon,
            cover: coverUrl
        )

        let pageId = result["id"] as? String ?? "unknown"
        let url = result["url"] as? String ?? ""
        return "Page created: **\(title)**\nID: `\(pageId)`\nURL: \(url)"
    }

    private func detectIsDatabase(_ id: String) async -> Bool {
        do {
            _ = try await NotionAPI.shared.getDatabase(id: id)
            return true
        } catch {
            return false
        }
    }

    private func buildDatabaseProperties(databaseId: String, title: String, rawProperties: [String: Any]) async throws -> [String: Any] {
        // Fetch database schema to know property types
        let db = try await NotionAPI.shared.getDatabase(id: databaseId)
        guard let schema = db["properties"] as? [String: Any] else {
            // Fallback: just set title
            return ["title": [["text": ["content": title]]] as [[String: Any]]]
        }

        var properties: [String: Any] = [:]

        // Find and set the title property
        for (propName, propDef) in schema {
            if let def = propDef as? [String: Any], def["type"] as? String == "title" {
                properties[propName] = ["title": [["text": ["content": title]]] as [[String: Any]]]
                break
            }
        }

        // Map raw property values using schema types
        for (key, value) in rawProperties {
            guard let propDef = schema[key] as? [String: Any],
                  let propType = propDef["type"] as? String else { continue }

            if let built = NotionPropertyFormatter.buildPropertyValue(type: propType, value: value) {
                properties[key] = built
            }
        }

        return properties
    }
}

// MARK: - Update Page

struct NotionUpdatePageTool: ToolDefinition {
    let name = "notion_update_page"
    let description = "Update a Notion page's properties, icon, or cover image. Can also archive/unarchive pages."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "page_id": JSONSchema.string(description: "The page ID to update"),
            "properties": JSONSchema.string(description: "JSON object of properties to update. Keys are property names."),
            "icon": JSONSchema.string(description: "New icon emoji"),
            "cover_url": JSONSchema.string(description: "New cover image URL"),
            "archived": JSONSchema.boolean(description: "Set true to archive, false to unarchive")
        ], required: ["page_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pageId = try requiredString("page_id", from: args)
        let propsJSON = optionalString("properties", from: args)
        let icon = optionalString("icon", from: args)
        let coverUrl = optionalString("cover_url", from: args)
        let archived = optionalBool("archived", from: args)

        var properties: [String: Any]? = nil
        if let propsJSON = propsJSON,
           let data = propsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            properties = parsed
        }

        let result = try await NotionAPI.shared.updatePage(
            id: pageId, properties: properties,
            icon: icon, cover: coverUrl, archived: archived
        )

        let url = result["url"] as? String ?? ""
        return "Page updated.\nURL: \(url)"
    }
}

// MARK: - Append Blocks

struct NotionAppendBlocksTool: ToolDefinition {
    let name = "notion_append_blocks"
    let description = "Append content to an existing Notion page. Write in markdown — it will be appended as new blocks at the end of the page."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "page_id": JSONSchema.string(description: "The page ID to append to"),
            "content": JSONSchema.string(description: "Content in markdown format to append")
        ], required: ["page_id", "content"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pageId = try requiredString("page_id", from: args)
        let content = try requiredString("content", from: args)

        let blocks = NotionBlockBuilder.markdownToBlocks(content)
        guard !blocks.isEmpty else {
            return "No content to append (empty or unparseable markdown)."
        }

        _ = try await NotionAPI.shared.appendBlocks(blockId: pageId, children: blocks)
        return "Appended \(blocks.count) block(s) to the page."
    }
}

// MARK: - Query Database

struct NotionQueryDatabaseTool: ToolDefinition {
    let name = "notion_query_database"
    let description = "Query a Notion database with optional filters and sorting. Returns entries with their properties."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "database_id": JSONSchema.string(description: "The database ID to query"),
            "filter": JSONSchema.string(description: "JSON filter object (Notion filter format). Example: {\"property\": \"Status\", \"select\": {\"equals\": \"Done\"}}"),
            "sorts": JSONSchema.string(description: "JSON array of sort objects. Example: [{\"property\": \"Date\", \"direction\": \"descending\"}]"),
            "limit": JSONSchema.integer(description: "Max results (default 20, max 100)", minimum: 1, maximum: 100)
        ], required: ["database_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let dbId = try requiredString("database_id", from: args)
        let limit = optionalInt("limit", from: args) ?? 20

        var filter: [String: Any]? = nil
        if let filterJSON = optionalString("filter", from: args),
           let data = filterJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            filter = parsed
        }

        var sorts: [[String: Any]]? = nil
        if let sortsJSON = optionalString("sorts", from: args),
           let data = sortsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            sorts = parsed
        }

        let result = try await NotionAPI.shared.queryDatabase(id: dbId, filter: filter, sorts: sorts, pageSize: limit)
        guard let entries = result["results"] as? [[String: Any]], !entries.isEmpty else {
            return "No entries found in this database."
        }

        var lines: [String] = ["Found \(entries.count) entries:"]
        for entry in entries {
            let id = entry["id"] as? String ?? ""
            let title = extractTitle(from: entry)
            let icon = extractIcon(from: entry)

            lines.append("")
            lines.append("\(icon) **\(title)** — `\(id)`")

            if let properties = entry["properties"] as? [String: Any] {
                let propsStr = NotionPropertyFormatter.formatProperties(properties)
                if !propsStr.isEmpty { lines.append(propsStr) }
            }
        }

        let hasMore = result["has_more"] as? Bool ?? false
        if hasMore { lines.append("\n*(More results available — increase limit or use pagination)*") }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Get Database Schema

struct NotionGetDatabaseTool: ToolDefinition {
    let name = "notion_get_database"
    let description = "Get a Notion database's schema — its title, properties (columns), and their types. Useful before querying or adding entries."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "database_id": JSONSchema.string(description: "The database ID")
        ], required: ["database_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let dbId = try requiredString("database_id", from: args)

        let db = try await NotionAPI.shared.getDatabase(id: dbId)

        let title = extractTitle(from: db)
        let icon = extractIcon(from: db)

        var lines: [String] = ["\(icon) **\(title)** (database)"]
        lines.append("ID: `\(db["id"] as? String ?? "")`")

        if let properties = db["properties"] as? [String: Any] {
            lines.append("")
            lines.append("**Properties (columns):**")
            for (name, propDef) in properties.sorted(by: { $0.key < $1.key }) {
                guard let def = propDef as? [String: Any],
                      let type = def["type"] as? String else { continue }

                var detail = type
                // Add extra info for select/multi_select (show options)
                if type == "select" || type == "multi_select",
                   let selectDef = def[type] as? [String: Any],
                   let options = selectDef["options"] as? [[String: Any]] {
                    let optNames = options.compactMap { $0["name"] as? String }.prefix(10)
                    if !optNames.isEmpty { detail += " [\(optNames.joined(separator: ", "))]" }
                }
                if type == "status",
                   let statusDef = def["status"] as? [String: Any],
                   let options = statusDef["options"] as? [[String: Any]] {
                    let optNames = options.compactMap { $0["name"] as? String }
                    if !optNames.isEmpty { detail += " [\(optNames.joined(separator: ", "))]" }
                }

                lines.append("- **\(name)**: \(detail)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Add Database Entry

struct NotionAddToDatabaseTool: ToolDefinition {
    let name = "notion_add_to_database"
    let description = "Add a new entry (row) to a Notion database. Specify property values as key-value pairs. Use notion_get_database first to see available properties and their types."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "database_id": JSONSchema.string(description: "The database ID to add an entry to"),
            "properties": JSONSchema.string(description: "JSON object mapping property names to values. Example: {\"Name\": \"My Task\", \"Status\": \"In Progress\", \"Priority\": \"High\", \"Due Date\": \"2024-12-31\"}"),
            "content": JSONSchema.string(description: "Optional markdown content for the page body of this entry"),
            "icon": JSONSchema.string(description: "Entry icon as emoji")
        ], required: ["database_id", "properties"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let dbId = try requiredString("database_id", from: args)
        let propsJSON = try requiredString("properties", from: args)
        let content = optionalString("content", from: args)
        let icon = optionalString("icon", from: args)

        guard let propsData = propsJSON.data(using: .utf8),
              let rawProps = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
            return "Invalid properties JSON. Provide a JSON object like {\"Name\": \"value\", \"Status\": \"Done\"}"
        }

        // Fetch database schema to build proper property values
        let db = try await NotionAPI.shared.getDatabase(id: dbId)
        guard let schema = db["properties"] as? [String: Any] else {
            return "Could not read database schema."
        }

        var properties: [String: Any] = [:]
        for (key, value) in rawProps {
            guard let propDef = schema[key] as? [String: Any],
                  let propType = propDef["type"] as? String else {
                continue
            }
            if let built = NotionPropertyFormatter.buildPropertyValue(type: propType, value: value) {
                properties[key] = built
            }
        }

        if properties.isEmpty {
            return "No valid properties matched the database schema. Use notion_get_database to see available properties."
        }

        var children: [[String: Any]]? = nil
        if let content = content, !content.isEmpty {
            children = NotionBlockBuilder.markdownToBlocks(content)
        }

        let result = try await NotionAPI.shared.createPage(
            parent: ["database_id": dbId.notionIDCleaned],
            properties: properties,
            children: children,
            icon: icon
        )

        let entryId = result["id"] as? String ?? ""
        let url = result["url"] as? String ?? ""
        let title = extractTitle(from: result)
        return "Entry added: **\(title)**\nID: `\(entryId)`\nURL: \(url)"
    }
}

// MARK: - Create Database

struct NotionCreateDatabaseTool: ToolDefinition {
    let name = "notion_create_database"
    let description = """
    Create a new database (table) in Notion under a parent page. Define columns with their types. \
    Supported types: title, rich_text, number, select, multi_select, status, date, checkbox, url, email, phone_number, files, people.
    """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "parent_page_id": JSONSchema.string(description: "Page ID where the database will be created"),
            "title": JSONSchema.string(description: "Database title"),
            "properties": JSONSchema.string(description: "JSON object defining columns. Example: {\"Name\": \"title\", \"Status\": {\"type\": \"select\", \"options\": [\"Todo\", \"In Progress\", \"Done\"]}, \"Due\": \"date\", \"Notes\": \"rich_text\", \"Priority\": {\"type\": \"select\", \"options\": [\"Low\", \"Medium\", \"High\"]}}")
        ], required: ["parent_page_id", "title", "properties"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let parentId = try requiredString("parent_page_id", from: args)
        let title = try requiredString("title", from: args)
        let propsJSON = try requiredString("properties", from: args)

        guard let propsData = propsJSON.data(using: .utf8),
              let rawProps = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
            return "Invalid properties JSON."
        }

        var notionProperties: [String: Any] = [:]
        for (name, spec) in rawProps {
            if let typeStr = spec as? String {
                // Simple type: "Name": "title"
                notionProperties[name] = buildPropertyDef(type: typeStr)
            } else if let specDict = spec as? [String: Any], let type = specDict["type"] as? String {
                // Complex type with options: {"type": "select", "options": ["A", "B"]}
                var propDef = buildPropertyDef(type: type)
                if let options = specDict["options"] as? [String] {
                    let optionDefs = options.map { ["name": $0] as [String: Any] }
                    if type == "select" { propDef["select"] = ["options": optionDefs] }
                    if type == "multi_select" { propDef["multi_select"] = ["options": optionDefs] }
                    if type == "status" { propDef["status"] = ["options": optionDefs] }
                }
                notionProperties[name] = propDef
            }
        }

        // Ensure there's a title property
        if !notionProperties.values.contains(where: { ($0 as? [String: Any])?["title"] != nil }) {
            notionProperties["Name"] = ["title": [:] as [String: Any]]
        }

        let result = try await NotionAPI.shared.createDatabase(
            parentPageId: parentId, title: title, properties: notionProperties
        )

        let dbId = result["id"] as? String ?? ""
        let url = result["url"] as? String ?? ""
        return "Database created: **\(title)**\nID: `\(dbId)`\nURL: \(url)"
    }

    private func buildPropertyDef(type: String) -> [String: Any] {
        switch type {
        case "title": return ["title": [:] as [String: Any]]
        case "rich_text": return ["rich_text": [:] as [String: Any]]
        case "number": return ["number": [:] as [String: Any]]
        case "select": return ["select": [:] as [String: Any]]
        case "multi_select": return ["multi_select": [:] as [String: Any]]
        case "status": return ["status": [:] as [String: Any]]
        case "date": return ["date": [:] as [String: Any]]
        case "checkbox": return ["checkbox": [:] as [String: Any]]
        case "url": return ["url": [:] as [String: Any]]
        case "email": return ["email": [:] as [String: Any]]
        case "phone_number": return ["phone_number": [:] as [String: Any]]
        case "files": return ["files": [:] as [String: Any]]
        case "people": return ["people": [:] as [String: Any]]
        default: return ["rich_text": [:] as [String: Any]]
        }
    }
}

// MARK: - Add Comment

struct NotionAddCommentTool: ToolDefinition {
    let name = "notion_add_comment"
    let description = "Add a comment to a Notion page."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "page_id": JSONSchema.string(description: "The page ID to comment on"),
            "text": JSONSchema.string(description: "Comment text (supports basic markdown: **bold**, *italic*)")
        ], required: ["page_id", "text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pageId = try requiredString("page_id", from: args)
        let text = try requiredString("text", from: args)

        let richText = NotionBlockBuilder.parseInlineMarkdown(text)
        _ = try await NotionAPI.shared.createComment(pageId: pageId, richText: richText)
        return "Comment added to page."
    }
}

// MARK: - Helper Functions (shared across tools)

private func extractTitle(from object: [String: Any]) -> String {
    // Try properties.title or properties.Name (database entries)
    if let properties = object["properties"] as? [String: Any] {
        for (_, propVal) in properties {
            guard let prop = propVal as? [String: Any],
                  prop["type"] as? String == "title" else { continue }
            let text = NotionBlockReader.extractPlainText(prop["title"])
            if !text.isEmpty { return text }
        }
    }
    // Try top-level title (databases)
    if let title = object["title"] as? [[String: Any]] {
        let text = NotionBlockReader.extractPlainText(title)
        if !text.isEmpty { return text }
    }
    return "Untitled"
}

private func extractIcon(from object: [String: Any]) -> String {
    guard let icon = object["icon"] as? [String: Any] else { return "" }
    if let emoji = icon["emoji"] as? String { return emoji }
    return ""
}

private func formatDate(_ isoDate: String) -> String {
    // Simple: just show the date part
    if let tIndex = isoDate.firstIndex(of: "T") {
        return String(isoDate[..<tIndex])
    }
    return isoDate
}
