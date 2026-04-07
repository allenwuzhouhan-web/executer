import Foundation

/// When a namespace approaches the 200-memory limit, consolidates related memories
/// into fewer, denser summaries using an LLM.
actor MemoryConsolidator {
    static let shared = MemoryConsolidator()

    /// Threshold: start consolidation at 160 memories (80% of 200 limit).
    private let consolidationThreshold = 160

    /// Check if consolidation is needed and perform it.
    func consolidateIfNeeded(namespace: String) async {
        let memories = MemoryManager.shared.memories(for: namespace)
        guard memories.count >= consolidationThreshold else { return }

        print("[MemoryConsolidator] Namespace '\(namespace)' has \(memories.count) memories, consolidating...")

        // Group memories by category and keyword overlap
        let groups = groupRelatedMemories(memories)

        // For each group with 3+ memories, summarize into one
        var consolidated = 0
        for group in groups where group.count >= 3 {
            guard let summary = await summarizeGroup(group) else { continue }

            // Remove the originals
            for mem in group {
                _ = MemoryManager.shared.forgetById(mem.id, namespace: namespace)
            }
            // Add the consolidated memory with union of keywords
            let allKeywords = Array(Set(group.flatMap(\.keywords)))
            MemoryManager.shared.add(
                content: summary,
                category: group[0].category,
                keywords: allKeywords,
                namespace: namespace
            )
            consolidated += group.count - 1
        }

        if consolidated > 0 {
            print("[MemoryConsolidator] Consolidated \(consolidated) memories in '\(namespace)'")
        }
    }

    private func groupRelatedMemories(_ memories: [MemoryManager.Memory]) -> [[MemoryManager.Memory]] {
        var groups: [[MemoryManager.Memory]] = []
        var assigned = Set<UUID>()

        let byCategory = Dictionary(grouping: memories, by: \.category)
        for (_, catMemories) in byCategory {
            for mem in catMemories where !assigned.contains(mem.id) {
                var group = [mem]
                assigned.insert(mem.id)
                let memKeywords = Set(mem.keywords.map { $0.lowercased() })

                for other in catMemories where !assigned.contains(other.id) {
                    let otherKeywords = Set(other.keywords.map { $0.lowercased() })
                    let intersection = memKeywords.intersection(otherKeywords)
                    let union = memKeywords.union(otherKeywords)
                    let jaccard = union.isEmpty ? 0 : Double(intersection.count) / Double(union.count)
                    if jaccard >= 0.3 {
                        group.append(other)
                        assigned.insert(other.id)
                    }
                }
                groups.append(group)
            }
        }
        return groups
    }

    private func summarizeGroup(_ group: [MemoryManager.Memory]) async -> String? {
        let contents = group.map(\.content).joined(separator: "\n- ")
        let prompt = "Consolidate these related memories into a single concise memory (1-2 sentences). Preserve all important facts.\n- \(contents)"

        let messages = [
            ChatMessage(role: "system", content: "Summarize related memories into one concise statement. Preserve all important facts. Output ONLY the consolidated memory text."),
            ChatMessage(role: "user", content: prompt)
        ]

        let service = LLMServiceManager.shared.currentService
        guard let response = try? await service.sendChatRequest(
            messages: messages, tools: nil, maxTokens: 200
        ), let text = response.text else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
