import Foundation

/// Persisted library of (goal_pattern → tool_chain) mappings, fuzzy-matched by semantic similarity.
final class CompositionCache {
    static let shared = CompositionCache()

    private var entries: [CacheEntry] = []
    private let lock = NSLock()
    private let maxEntries = 100

    struct CacheEntry: Codable {
        let goalPattern: String
        let toolChain: [String]       // Ordered list of tool names
        let argumentTemplates: [String] // JSON argument templates per tool
        let successCount: Int
        let lastUsed: Date
        let createdAt: Date
    }

    private static var storageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("tool_compositions.json")
    }

    init() {
        lock.lock()
        entries = Self.loadFromDisk()
        lock.unlock()
    }

    // MARK: - Lookup

    /// Find the best matching composition for a goal description.
    func findMatch(goal: String, threshold: Double = 0.6) -> CacheEntry? {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard !snapshot.isEmpty else { return nil }

        var bestMatch: CacheEntry?
        var bestScore: Double = 0

        for entry in snapshot {
            let score = TextEmbedder.textSimilarity(goal, entry.goalPattern)
            if score > bestScore && score >= threshold {
                bestScore = score
                bestMatch = entry
            }
        }

        return bestMatch
    }

    // MARK: - Store

    /// Record a successful tool composition.
    func record(goal: String, toolChain: [String], argumentTemplates: [String]) {
        lock.lock()

        // Check for existing similar entry
        if let idx = entries.firstIndex(where: {
            TextEmbedder.textSimilarity(goal, $0.goalPattern) > 0.85
        }) {
            // Update existing — increment success count
            var updated = entries[idx]
            updated = CacheEntry(
                goalPattern: updated.goalPattern,
                toolChain: toolChain,
                argumentTemplates: argumentTemplates,
                successCount: updated.successCount + 1,
                lastUsed: Date(),
                createdAt: updated.createdAt
            )
            entries[idx] = updated
        } else {
            entries.append(CacheEntry(
                goalPattern: goal,
                toolChain: toolChain,
                argumentTemplates: argumentTemplates,
                successCount: 1,
                lastUsed: Date(),
                createdAt: Date()
            ))
        }

        // Trim to max entries (evict least-used)
        if entries.count > maxEntries {
            entries.sort { $0.successCount > $1.successCount }
            entries = Array(entries.prefix(maxEntries))
        }

        lock.unlock()
        save()
    }

    // MARK: - Persistence

    private func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private static func loadFromDisk() -> [CacheEntry] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CacheEntry].self, from: data)) ?? []
    }
}
