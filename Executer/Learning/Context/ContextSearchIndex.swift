import Foundation

/// Lightweight in-memory inverted index over daily summary files.
/// Maps keywords to (date, sessionIndex) for fast retrieval.
/// ~50KB in memory for 6 months of data.
final class ContextSearchIndex {
    static let shared = ContextSearchIndex()

    /// Keyword → list of (date, session title) pairs.
    private var index: [String: [(date: String, title: String)]] = [:]
    private let lock = NSLock()

    private init() {
        rebuildIndex()
    }

    /// Rebuild the index from daily summary files.
    func rebuildIndex() {
        lock.lock()
        defer { lock.unlock() }

        index.removeAll()

        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer/daily_summaries", isDirectory: true)

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let summary = try? JSONDecoder().decode(DailySummary.self, from: data) else { continue }

            // Index top topics
            for topic in summary.topTopics {
                let key = topic.lowercased()
                index[key, default: []].append((summary.date, topic))
            }

            // Index session titles and topics
            for session in summary.sessions {
                let keywords = NLPipeline.extractKeywords(from: session.title, limit: 5)
                for keyword in keywords {
                    index[keyword.lowercased(), default: []].append((summary.date, session.title))
                }
                for topic in session.topics {
                    index[topic.lowercased(), default: []].append((summary.date, session.title))
                }
            }
        }

        print("[ContextSearchIndex] Indexed \(index.count) keywords from \(files.count) summaries")
    }

    /// Search the index for matching sessions.
    func search(query: String, limit: Int = 5) -> [(date: String, title: String)] {
        lock.lock()
        defer { lock.unlock() }

        let queryWords = query.lowercased().split(separator: " ").map(String.init)
        var scores: [String: (date: String, title: String, score: Int)] = [:]

        for word in queryWords {
            // Exact match
            if let matches = index[word] {
                for match in matches {
                    let key = "\(match.date):\(match.title)"
                    if var existing = scores[key] {
                        existing.score += 1
                        scores[key] = existing
                    } else {
                        scores[key] = (match.date, match.title, 1)
                    }
                }
            }

            // Prefix match
            for (indexWord, matches) in index where indexWord.hasPrefix(word) && indexWord != word {
                for match in matches {
                    let key = "\(match.date):\(match.title)"
                    if scores[key] == nil {
                        scores[key] = (match.date, match.title, 1)
                    }
                }
            }
        }

        return scores.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { ($0.date, $0.title) }
    }
}
