import Foundation

/// Persistent cross-session memory for the LLM agent.
class MemoryManager {
    static let shared = MemoryManager()

    enum MemoryCategory: String, Codable, CaseIterable {
        case preference
        case fact
        case task
        case note
    }

    struct Memory: Codable, Identifiable {
        let id: UUID
        var content: String
        var category: MemoryCategory
        var keywords: [String]
        let createdAt: Date
        var lastAccessedAt: Date
        var accessCount: Int
    }

    private(set) var memories: [Memory] = []
    private let maxMemories = 200

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memories.json")
    }()

    private init() {
        load()
        print("[Memory] Loaded \(memories.count) memories")
    }

    // MARK: - CRUD

    @discardableResult
    func add(content: String, category: MemoryCategory, keywords: [String]? = nil) -> Memory {
        let resolvedKeywords = keywords ?? extractKeywords(from: content)
        let memory = Memory(
            id: UUID(),
            content: content,
            category: category,
            keywords: resolvedKeywords,
            createdAt: Date(),
            lastAccessedAt: Date(),
            accessCount: 0
        )
        memories.append(memory)

        // Enforce limit — remove oldest, lowest-access memories
        if memories.count > maxMemories {
            memories.sort { $0.accessCount < $1.accessCount }
            memories.removeFirst(memories.count - maxMemories)
        }

        save()
        print("[Memory] Added \(category.rawValue): \(content.prefix(60))...")
        return memory
    }

    func recall(query: String? = nil, category: MemoryCategory? = nil, limit: Int = 10) -> [Memory] {
        var results = memories

        if let category = category {
            results = results.filter { $0.category == category }
        }

        if let query = query, !query.isEmpty {
            let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
            results = results.sorted { a, b in
                score(memory: a, queryWords: queryWords) > score(memory: b, queryWords: queryWords)
            }
        } else {
            results.sort { $0.lastAccessedAt > $1.lastAccessedAt }
        }

        let topResults = Array(results.prefix(limit))

        // Update access counts
        for result in topResults {
            if let idx = memories.firstIndex(where: { $0.id == result.id }) {
                memories[idx].lastAccessedAt = Date()
                memories[idx].accessCount += 1
            }
        }
        save()

        return topResults
    }

    func forget(query: String) -> Bool {
        let lowered = query.lowercased()
        if let idx = memories.firstIndex(where: { $0.content.lowercased().contains(lowered) }) {
            let removed = memories.remove(at: idx)
            save()
            print("[Memory] Forgot: \(removed.content.prefix(60))...")
            return true
        }
        return false
    }

    func list(category: MemoryCategory? = nil) -> [Memory] {
        if let category = category {
            return memories.filter { $0.category == category }
        }
        return memories
    }

    // MARK: - System Prompt Injection

    /// Build a memory section for the system prompt, relevant to the given query.
    func promptSection(query: String) -> String {
        guard !memories.isEmpty else { return "" }

        var included: [Memory] = []
        var includedIDs = Set<UUID>()

        // Always include preference memories (up to 20)
        let prefs = memories.filter { $0.category == .preference }.prefix(20)
        for mem in prefs {
            included.append(mem)
            includedIDs.insert(mem.id)
        }

        // Score remaining by relevance
        let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
        let remaining = memories.filter { !includedIDs.contains($0.id) }
        let scored = remaining.sorted { a, b in
            score(memory: a, queryWords: queryWords) > score(memory: b, queryWords: queryWords)
        }

        // Add top 10 scored
        for mem in scored.prefix(10) {
            if !includedIDs.contains(mem.id) {
                included.append(mem)
                includedIDs.insert(mem.id)
            }
        }

        // Add 3 most recent (deduped)
        let recent = memories.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
        for mem in recent.prefix(3) {
            if !includedIDs.contains(mem.id) {
                included.append(mem)
                includedIDs.insert(mem.id)
            }
        }

        // Cap total output at ~2000 chars
        var lines: [String] = ["\n## Your Memory"]

        let prefLines = included.filter { $0.category == .preference }
        if !prefLines.isEmpty {
            lines.append("**Preferences:**")
            for mem in prefLines {
                lines.append("- \(mem.content)")
            }
        }

        let contextLines = included.filter { $0.category != .preference }
        if !contextLines.isEmpty {
            lines.append("**Relevant Context:**")
            for mem in contextLines {
                lines.append("- [\(mem.category.rawValue)] \(mem.content)")
            }
        }

        var result = lines.joined(separator: "\n")
        if result.count > 2000 {
            result = String(result.prefix(2000)) + "\n(truncated)"
        }
        return result
    }

    // MARK: - Helpers

    private func score(memory: Memory, queryWords: Set<String>) -> Double {
        // Keyword overlap
        let memWords = Set(memory.keywords.map { $0.lowercased() })
        let overlap = Double(memWords.intersection(queryWords).count)

        // Recency boost (last 24h)
        let hoursSinceAccess = Date().timeIntervalSince(memory.lastAccessedAt) / 3600
        let recencyBoost = hoursSinceAccess < 24 ? 1.0 : 0.0

        // Category weight
        let categoryWeight: Double
        switch memory.category {
        case .preference: categoryWeight = 2.0
        case .fact: categoryWeight = 1.5
        case .task: categoryWeight = 1.0
        case .note: categoryWeight = 0.5
        }

        return overlap * 2.0 + recencyBoost + categoryWeight
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "as", "into", "about", "like",
        "through", "after", "over", "between", "out", "up", "down", "off",
        "it", "its", "i", "my", "me", "we", "our", "you", "your", "he",
        "she", "they", "them", "this", "that", "and", "or", "but", "not",
    ]

    func extractKeywords(from text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopWords.contains($0) }
        return Array(Set(words))
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(memories)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[Memory] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            memories = try decoder.decode([Memory].self, from: data)
        } catch {
            print("[Memory] Failed to load: \(error)")
        }
    }
}
