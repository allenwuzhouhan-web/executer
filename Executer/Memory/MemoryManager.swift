import Foundation

/// Persistent cross-session memory for the LLM agent, scoped by namespace per agent.
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
        var namespace: String

        init(id: UUID = UUID(), content: String, category: MemoryCategory, keywords: [String],
             createdAt: Date = Date(), lastAccessedAt: Date = Date(), accessCount: Int = 0,
             namespace: String = "general") {
            self.id = id
            self.content = content
            self.category = category
            self.keywords = keywords
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
            self.accessCount = accessCount
            self.namespace = namespace
        }

        // Backward-compatible decoding: if namespace is missing, default to "general"
        enum CodingKeys: String, CodingKey {
            case id, content, category, keywords, createdAt, lastAccessedAt, accessCount, namespace
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            content = try c.decode(String.self, forKey: .content)
            category = try c.decode(MemoryCategory.self, forKey: .category)
            keywords = try c.decode([String].self, forKey: .keywords)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            lastAccessedAt = try c.decode(Date.self, forKey: .lastAccessedAt)
            accessCount = try c.decode(Int.self, forKey: .accessCount)
            namespace = try c.decodeIfPresent(String.self, forKey: .namespace) ?? "general"
        }
    }

    /// All memories across all namespaces (keyed by namespace)
    private var memoriesByNamespace: [String: [Memory]] = [:]
    private let maxMemoriesPerNamespace = 200
    /// Serial queue for thread-safe access to memoriesByNamespace
    private let queue = DispatchQueue(label: "com.executer.memory", qos: .utility)

    private let memoriesDir: URL
    private let legacyStorageURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        memoriesDir = baseDir.appendingPathComponent("memories", isDirectory: true)
        legacyStorageURL = baseDir.appendingPathComponent("memories.json")

        try? FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)

        migrateIfNeeded()
        loadAll()

        let total = memoriesByNamespace.values.reduce(0) { $0 + $1.count }
        print("[Memory] Loaded \(total) memories across \(memoriesByNamespace.count) namespace(s)")
    }

    // MARK: - Public Access (backward-compatible)

    /// All memories in a given namespace.
    var memories: [Memory] {
        queue.sync { memoriesByNamespace["general"] ?? [] }
    }

    func memories(for namespace: String) -> [Memory] {
        queue.sync { memoriesByNamespace[namespace] ?? [] }
    }

    // MARK: - CRUD

    @discardableResult
    func add(content: String, category: MemoryCategory, keywords: [String]? = nil, namespace: String = "general") -> Memory {
        let resolvedKeywords = keywords ?? extractKeywords(from: content)
        let memory = Memory(
            content: content,
            category: category,
            keywords: resolvedKeywords,
            namespace: namespace
        )

        queue.sync {
            memoriesByNamespace[namespace, default: []].append(memory)

            // Enforce limit per namespace
            if let count = memoriesByNamespace[namespace]?.count, count > maxMemoriesPerNamespace {
                memoriesByNamespace[namespace]?.sort { $0.accessCount < $1.accessCount }
                memoriesByNamespace[namespace]?.removeFirst(count - maxMemoriesPerNamespace)
            }

            save(namespace: namespace)
        }
        // Invalidate frozen memory cache so new memories are visible to LLM
        LLMServiceManager.shared.refreshMemoryCache()
        print("[Memory] Added \(category.rawValue) in '\(namespace)': \(content.prefix(60))...")

        // Trigger consolidation if approaching limit
        Task { await MemoryConsolidator.shared.consolidateIfNeeded(namespace: namespace) }

        return memory
    }

    func recall(query: String? = nil, category: MemoryCategory? = nil, limit: Int = 10, namespace: String = "general") -> [Memory] {
        return queue.sync {
            var results = memoriesByNamespace[namespace] ?? []

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
                if let idx = memoriesByNamespace[namespace]?.firstIndex(where: { $0.id == result.id }) {
                    memoriesByNamespace[namespace]?[idx].lastAccessedAt = Date()
                    memoriesByNamespace[namespace]?[idx].accessCount += 1
                }
            }
            save(namespace: namespace)

            return topResults
        }
    }

    func forget(query: String, namespace: String = "general") -> Bool {
        return queue.sync {
            let lowered = query.lowercased()
            if let idx = memoriesByNamespace[namespace]?.firstIndex(where: { $0.content.lowercased().contains(lowered) }) {
                let removed = memoriesByNamespace[namespace]?.remove(at: idx)
                save(namespace: namespace)
                print("[Memory] Forgot from '\(namespace)': \(removed?.content.prefix(60) ?? "")...")
                return true
            }
            return false
        }
    }

    /// Remove a memory by its UUID. Used by MemoryConsolidator.
    @discardableResult
    func forgetById(_ id: UUID, namespace: String = "general") -> Bool {
        return queue.sync {
            if let idx = memoriesByNamespace[namespace]?.firstIndex(where: { $0.id == id }) {
                memoriesByNamespace[namespace]?.remove(at: idx)
                save(namespace: namespace)
                return true
            }
            return false
        }
    }

    /// Async recall with semantic re-ranking for better accuracy.
    /// Fast path: keyword scoring for top-30, then LLM-based re-ranking.
    func recallSemantic(query: String, category: MemoryCategory? = nil, limit: Int = 10, namespace: String = "general") async -> [Memory] {
        let keywordResults = recall(query: query, category: category, limit: 30, namespace: namespace)
        guard keywordResults.count > 3 else { return keywordResults }
        let reranked = await SemanticMemoryScorer.shared.scoreRelevance(
            query: query, candidates: keywordResults, limit: limit
        )
        return reranked
    }

    func list(category: MemoryCategory? = nil, namespace: String = "general") -> [Memory] {
        return queue.sync {
            let all = memoriesByNamespace[namespace] ?? []
            if let category = category {
                return all.filter { $0.category == category }
            }
            return all
        }
    }

    // MARK: - System Prompt Injection

    /// Build a memory section for the system prompt, scoped by namespace.
    /// Includes general preferences + namespace-specific memories.
    func promptSection(query: String, namespace: String = "general") -> String {
        // Snapshot state under lock, then process outside
        let (generalPrefs, allMemories): (ArraySlice<Memory>, [Memory]) = queue.sync {
            let prefs = (memoriesByNamespace["general"] ?? [])
                .filter { $0.category == .preference }
                .prefix(20)
            let nsMemories = namespace == "general" ? [] : (memoriesByNamespace[namespace] ?? [])
            let all = (memoriesByNamespace["general"] ?? []) + nsMemories
            return (prefs, all)
        }
        guard !allMemories.isEmpty else { return "" }

        var included: [Memory] = []
        var includedIDs = Set<UUID>()

        // Always include preferences from general
        for mem in generalPrefs {
            included.append(mem)
            includedIDs.insert(mem.id)
        }

        // Score remaining by relevance
        let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
        let remaining = allMemories.filter { !includedIDs.contains($0.id) }
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
        let recent = allMemories.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
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
                let nsTag = mem.namespace != "general" ? " [\(mem.namespace)]" : ""
                lines.append("- [\(mem.category.rawValue)\(nsTag)] \(mem.content)")
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
        let memWords = Set(memory.keywords.map { $0.lowercased() })
        let overlap = Double(memWords.intersection(queryWords).count)

        let daysSinceAccess = Date().timeIntervalSince(memory.lastAccessedAt) / 86400
        let recencyBoost = pow(0.5, daysSinceAccess / 7.0)

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

    private func storageURL(for namespace: String) -> URL {
        memoriesDir.appendingPathComponent("\(namespace).json")
    }

    private func save(namespace: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(memoriesByNamespace[namespace] ?? [])
            try data.write(to: storageURL(for: namespace), options: .atomic)
        } catch {
            print("[Memory] Failed to save namespace '\(namespace)': \(error)")
        }
    }

    private func loadAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            let namespace = file.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: file)
                let memories = try decoder.decode([Memory].self, from: data)
                memoriesByNamespace[namespace] = memories
            } catch {
                print("[Memory] Failed to load namespace '\(namespace)': \(error)")
            }
        }
    }

    // MARK: - Migration

    /// Migrate from legacy single memories.json to namespaced directory.
    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyStorageURL.path) else { return }

        // Already migrated if general.json exists
        let generalURL = storageURL(for: "general")
        guard !fm.fileExists(atPath: generalURL.path) else { return }

        print("[Memory] Migrating from memories.json to namespaced storage...")
        do {
            let data = try Data(contentsOf: legacyStorageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var oldMemories = try decoder.decode([Memory].self, from: data)

            // Assign namespace = "general" to all
            for i in oldMemories.indices {
                oldMemories[i].namespace = "general"
            }

            memoriesByNamespace["general"] = oldMemories
            save(namespace: "general")

            // Rename legacy file as backup
            let backupURL = legacyStorageURL.appendingPathExtension("migrated")
            try fm.moveItem(at: legacyStorageURL, to: backupURL)
            print("[Memory] Migration complete: \(oldMemories.count) memories → general namespace")
        } catch {
            print("[Memory] Migration failed: \(error)")
        }
    }
}
