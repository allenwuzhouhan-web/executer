import Foundation

// MARK: - Save Memory

struct SaveMemoryTool: ToolDefinition {
    let name = "save_memory"
    let description = "Save something to memory for future sessions. Use for user preferences, facts, tasks, or notes you want to remember."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "content": JSONSchema.string(description: "What to remember (e.g. 'User prefers dark mode', 'Project uses SwiftUI')"),
            "category": JSONSchema.enumString(description: "Category of memory", values: ["preference", "fact", "task", "note"]),
            "keywords": JSONSchema.string(description: "Optional comma-separated keywords for better recall (auto-extracted if omitted)"),
        ], required: ["content", "category"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let content = try requiredString("content", from: args)
        let categoryStr = try requiredString("category", from: args)

        guard let category = MemoryManager.MemoryCategory(rawValue: categoryStr) else {
            return "Invalid category: \(categoryStr). Use: preference, fact, task, or note."
        }

        let keywords: [String]?
        if let kw = optionalString("keywords", from: args) {
            keywords = kw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            keywords = nil
        }

        let memory = MemoryManager.shared.add(content: content, category: category, keywords: keywords)
        return "Saved to memory [\(category.rawValue)]: \(memory.content)"
    }
}

// MARK: - Recall Memories

struct RecallMemoriesTool: ToolDefinition {
    let name = "recall_memories"
    let description = "Search your memories for relevant information. Use when you need to remember something from a previous session."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query to find relevant memories"),
            "category": JSONSchema.enumString(description: "Filter by category", values: ["preference", "fact", "task", "note"]),
            "limit": JSONSchema.integer(description: "Maximum memories to return (default 10)", minimum: 1, maximum: 50),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = optionalString("query", from: args)
        let categoryStr = optionalString("category", from: args)
        let limit = optionalInt("limit", from: args) ?? 10

        let category = categoryStr.flatMap { MemoryManager.MemoryCategory(rawValue: $0) }
        let results = MemoryManager.shared.recall(query: query, category: category, limit: limit)

        if results.isEmpty {
            return "No memories found\(query.map { " matching '\($0)'" } ?? "")."
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        var lines = ["Found \(results.count) memories:"]
        for mem in results {
            let date = formatter.string(from: mem.createdAt)
            lines.append("[\(mem.category.rawValue)] \(mem.content) (saved \(date))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Forget Memory

struct ForgetMemoryTool: ToolDefinition {
    let name = "forget_memory"
    let description = "Delete a memory that matches the given query. Removes the first memory whose content contains the query text."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Text to search for in memory content"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)

        if MemoryManager.shared.forget(query: query) {
            return "Forgot memory matching '\(query)'."
        }
        return "No memory found matching '\(query)'."
    }
}

// MARK: - List Memories

struct ListMemoriesTool: ToolDefinition {
    let name = "list_memories"
    let description = "List all saved memories, optionally filtered by category."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "category": JSONSchema.enumString(description: "Filter by category", values: ["preference", "fact", "task", "note"]),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let categoryStr = optionalString("category", from: args)
        let category = categoryStr.flatMap { MemoryManager.MemoryCategory(rawValue: $0) }

        let memories = MemoryManager.shared.list(category: category)

        if memories.isEmpty {
            return "No memories saved\(category.map { " in category '\($0.rawValue)'" } ?? "")."
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short

        var lines = ["\(memories.count) memories:"]
        for mem in memories {
            let date = formatter.string(from: mem.createdAt)
            lines.append("[\(mem.category.rawValue)] \(mem.content) (\(date))")
        }
        return lines.joined(separator: "\n")
    }
}
