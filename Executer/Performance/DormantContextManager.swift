import Foundation

/// Manages Stage 5 (Far Peripheral) dormant context items with zero API cost.
///
/// Dormant items are old memories, stale goals, and unused skills that no longer
/// need to be injected into every system prompt. Instead, their embeddings are
/// stored as quantized vectors and checked against each query for activation.
///
/// Activation: when a user query has cosine similarity > 0.6 with a dormant item,
/// that item is promoted to active and injected into the current prompt.
final class DormantContextManager {
    static let shared = DormantContextManager()

    // MARK: - Configuration

    /// Memory is dormant if not accessed in this many days.
    private let memoryDormancyDays: TimeInterval = 14

    /// Goal is dormant if not updated in this many days (and no imminent deadline).
    private let goalDormancyDays: TimeInterval = 7

    /// Deadline proximity that overrides dormancy (hours).
    private let deadlineProximityHours: TimeInterval = 48

    /// Cosine similarity threshold for activating a dormant item.
    private let activationThreshold: Double = 0.6

    /// Max dormant items to activate per query.
    private let maxActivationsPerQuery = 3

    // MARK: - State

    /// IDs of dormant memories (excluded from prompt injection).
    private(set) var dormantMemoryIDs: Set<UUID> = []

    /// IDs of dormant goals.
    private(set) var dormantGoalIDs: Set<UUID> = []

    /// Quantized embeddings for dormant items, keyed by UUID.
    private var dormantEmbeddings: [UUID: [Double]] = [:]

    /// Content snippets for activated items (injected into prompt).
    private var dormantContent: [UUID: String] = [:]

    private let lock = NSLock()
    private var isScanned = false

    /// Cached goals snapshot (refreshed on each scan).
    private var cachedGoals: [ManagedGoal] = []

    private init() {}

    /// Refresh the goal cache from GoalStack (call from async context).
    func refreshGoalCache() async {
        let goals = await GoalStack.shared.allGoals()
        lock.lock()
        cachedGoals = goals
        lock.unlock()
    }

    // MARK: - Scanning

    /// Scan all memories and goals, classify as active or dormant.
    /// Call on app startup and periodically (e.g., every hour).
    func scan() {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        // Scan memories
        var newDormantMemoryIDs = Set<UUID>()
        let allMemories = MemoryManager.shared.list()
        for memory in allMemories {
            let daysSinceAccess = now.timeIntervalSince(memory.lastAccessedAt) / 86400
            if daysSinceAccess > memoryDormancyDays {
                newDormantMemoryIDs.insert(memory.id)
                dormantContent[memory.id] = memory.content

                // Compute and store embedding if not already cached
                if dormantEmbeddings[memory.id] == nil {
                    if let vec = TextEmbedder.sentenceVector(memory.content) {
                        dormantEmbeddings[memory.id] = vec
                    }
                }
            } else {
                // Re-activated by recent access — remove from dormant
                dormantEmbeddings.removeValue(forKey: memory.id)
                dormantContent.removeValue(forKey: memory.id)
            }
        }
        dormantMemoryIDs = newDormantMemoryIDs

        // Scan goals — note: GoalStack is an actor, we access the cached data synchronously
        var newDormantGoalIDs = Set<UUID>()
        let allGoals = cachedGoals
        for goal in allGoals {
            // Skip completed/failed goals
            guard goal.state == .pending || goal.state == .active || goal.state == .blocked else { continue }

            let daysSinceUpdate = now.timeIntervalSince(goal.updatedAt) / 86400

            // Check deadline proximity — never make dormant if deadline is close
            if let deadline = goal.deadline {
                let hoursUntilDeadline = deadline.timeIntervalSince(now) / 3600
                if hoursUntilDeadline > 0 && hoursUntilDeadline < deadlineProximityHours {
                    // Deadline approaching — keep active
                    dormantEmbeddings.removeValue(forKey: goal.id)
                    dormantContent.removeValue(forKey: goal.id)
                    continue
                }
            }

            if daysSinceUpdate > goalDormancyDays {
                newDormantGoalIDs.insert(goal.id)
                dormantContent[goal.id] = goal.title + ": " + goal.description

                if dormantEmbeddings[goal.id] == nil {
                    let goalText = goal.title + " " + goal.description
                    if let vec = TextEmbedder.sentenceVector(goalText) {
                        dormantEmbeddings[goal.id] = vec
                    }
                }
            } else {
                dormantEmbeddings.removeValue(forKey: goal.id)
                dormantContent.removeValue(forKey: goal.id)
            }
        }
        dormantGoalIDs = newDormantGoalIDs

        // Prune embeddings for items that no longer exist
        let allIDs = dormantMemoryIDs.union(dormantGoalIDs)
        for id in dormantEmbeddings.keys where !allIDs.contains(id) {
            dormantEmbeddings.removeValue(forKey: id)
            dormantContent.removeValue(forKey: id)
        }

        isScanned = true
        let total = dormantMemoryIDs.count + dormantGoalIDs.count
        if total > 0 {
            print("[DormantContext] Scanned: \(dormantMemoryIDs.count) dormant memories, \(dormantGoalIDs.count) dormant goals, \(dormantEmbeddings.count) embeddings cached")
        }
    }

    // MARK: - Activation (Query-Time)

    /// Check if any dormant items should be activated for the given query.
    /// Uses tiled cosine similarity (Flash Attention IO-aware) to efficiently
    /// compare the query against all dormant embeddings.
    /// Returns content strings for activated items to inject into the prompt.
    func activateForQuery(_ query: String) -> [String] {
        guard isScanned else {
            scan()
            guard !dormantEmbeddings.isEmpty else { return [] }
            // Fall through to activation check
            return activateForQuery(query)
        }

        guard !dormantEmbeddings.isEmpty else { return [] }

        guard let queryVec = TextEmbedder.sentenceVector(query) else { return [] }

        lock.lock()
        let embeddings = dormantEmbeddings
        let content = dormantContent
        lock.unlock()

        // Build candidate arrays for tiled similarity
        var ids: [UUID] = []
        var vectors: [[Double]] = []
        for (id, vec) in embeddings {
            ids.append(id)
            vectors.append(vec)
        }

        // Use Flash Attention tiled similarity for cache-efficient comparison
        let results = FlashAttentionUtils.tiledCosineSimilarity(
            query: queryVec, candidates: vectors, tileSize: 32
        )

        // Filter by activation threshold and rank with streaming softmax
        let activated = results
            .filter { $0.similarity > activationThreshold }
            .prefix(maxActivationsPerQuery)

        var activatedContent: [String] = []
        for match in activated {
            let id = ids[match.index]
            if let text = content[id] {
                activatedContent.append(text)
                print("[DormantContext] Activated: \(text.prefix(60))... (similarity: \(String(format: "%.3f", match.similarity)))")
            }
        }

        return activatedContent
    }

    /// Build a prompt section for activated dormant items.
    func activatedPromptSection(for query: String) -> String {
        let activated = activateForQuery(query)
        guard !activated.isEmpty else { return "" }

        var lines = ["\n## Recalled Context (dormant, activated by relevance)"]
        for item in activated {
            lines.append("- \(item)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Manual Promotion

    /// Manually promote a dormant item back to active (e.g., when user accesses it).
    func promote(id: UUID) {
        lock.lock()
        dormantMemoryIDs.remove(id)
        dormantGoalIDs.remove(id)
        dormantEmbeddings.removeValue(forKey: id)
        dormantContent.removeValue(forKey: id)
        lock.unlock()
    }
}
