import Foundation

/// Pre-built in-memory file index for instant search.
/// Scans user work directories on launch, caches all paths, and provides
/// sub-millisecond fuzzy search without any shell commands or permission prompts.
class FileIndex {
    static let shared = FileIndex()

    struct IndexedFile {
        let path: String
        let name: String       // original case
        let nameLower: String  // lowercased for search
        let size: UInt64
        let modified: Date
        let isDirectory: Bool
    }

    private var files: [IndexedFile] = []
    private var isIndexing = false
    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.executer.fileindex", qos: .utility)

    private init() {}

    // MARK: - Directories to index (only user work folders — never Music/Photos/Library)

    private var indexedDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents/works"),  // Priority folder
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
        ]
    }

    // MARK: - Public API

    /// Start indexing in the background. Called on app launch.
    func startIndexing() {
        buildIndex()

        // Re-index every 30 minutes
        DispatchQueue.main.async { [weak self] in
            self?.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                self?.buildIndex()
            }
        }
    }

    /// Force a re-index (e.g. after file operations).
    func reindex() {
        buildIndex()
    }

    /// Search the index. Returns results sorted by relevance then recency. Instant.
    func search(query: String, limit: Int = 10) -> [IndexedFile] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // Split query into words for multi-word matching
        let queryWords = q.split(separator: " ").map(String.init)

        let matched = files.filter { file in
            // All query words must appear in the filename or path
            queryWords.allSatisfy { word in
                file.nameLower.contains(word) || file.path.lowercased().contains(word)
            }
        }

        // Sort by relevance
        let sorted = matched.sorted { a, b in
            let aScore = relevanceScore(file: a, query: q, words: queryWords)
            let bScore = relevanceScore(file: b, query: q, words: queryWords)
            if aScore != bScore { return aScore > bScore }
            return a.modified > b.modified // tie-break: most recent first
        }

        return Array(sorted.prefix(limit))
    }

    /// Whether the index has been built at least once.
    var isReady: Bool { !files.isEmpty }

    /// Total number of indexed files.
    var count: Int { files.count }

    // MARK: - Indexing

    private func buildIndex() {
        guard !isIndexing else { return }
        isIndexing = true

        queue.async { [weak self] in
            guard let self = self else { return }
            let startTime = Date()
            var newFiles: [IndexedFile] = []
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.nameKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]

            for dir in self.indexedDirectories {
                guard fm.fileExists(atPath: dir.path) else { continue }

                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard let resources = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                    let name = resources.name ?? url.lastPathComponent
                    let isDir = resources.isDirectory ?? false

                    // Skip deep nesting (performance guard)
                    let depth = url.pathComponents.count - dir.pathComponents.count
                    if depth > 10 { enumerator.skipDescendants(); continue }

                    newFiles.append(IndexedFile(
                        path: url.path,
                        name: name,
                        nameLower: name.lowercased(),
                        size: UInt64(resources.fileSize ?? 0),
                        modified: resources.contentModificationDate ?? .distantPast,
                        isDirectory: isDir
                    ))
                }
            }

            // Deduplicate (Documents/works is inside Documents — remove dupes by path)
            var seen = Set<String>()
            newFiles = newFiles.filter { seen.insert($0.path).inserted }

            let elapsed = Date().timeIntervalSince(startTime)
            print("[FileIndex] Indexed \(newFiles.count) files in \(String(format: "%.2f", elapsed))s")

            self.files = newFiles
            self.isIndexing = false
        }
    }

    // MARK: - Relevance Scoring

    private func relevanceScore(file: IndexedFile, query: String, words: [String]) -> Int {
        var score = 0

        // Exact filename match (highest)
        if file.nameLower == query { score += 100 }

        // Filename starts with query
        if file.nameLower.hasPrefix(query) { score += 50 }

        // Filename contains full query as substring
        if file.nameLower.contains(query) { score += 30 }

        // All words in filename (not just path)
        if words.allSatisfy({ file.nameLower.contains($0) }) { score += 20 }

        // Boost files in works/G8 folder (user's primary workspace)
        if file.path.contains("/works/") { score += 10 }
        if file.path.contains("/G8/") { score += 5 }

        // Boost actual files over directories
        if !file.isDirectory { score += 3 }

        // Boost common document types
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ["pdf", "docx", "doc", "pptx", "xlsx", "txt", "md", "pages", "key", "numbers"].contains(ext) {
            score += 5
        }

        return score
    }
}
