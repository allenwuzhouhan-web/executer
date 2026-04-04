import Foundation

/// Uses a fast LLM call (DeepSeek) to score memory relevance when keyword scoring is insufficient.
/// Only called as a second pass on keyword-filtered top-K results.
actor SemanticMemoryScorer {
    static let shared = SemanticMemoryScorer()

    /// Score memories against a query using semantic similarity via LLM.
    func scoreRelevance(
        query: String,
        candidates: [MemoryManager.Memory],
        limit: Int = 10
    ) async -> [MemoryManager.Memory] {
        guard !query.isEmpty, candidates.count > 3 else {
            return Array(candidates.prefix(limit))
        }

        let memorySummaries = candidates.prefix(30).enumerated().map { (i, m) in
            "\(i): \(m.content.prefix(100))"
        }.joined(separator: "\n")

        let prompt = """
        Rate the relevance of each memory to the query. \
        Output ONLY a JSON array of indices sorted by relevance (highest first).
        Query: "\(query)"
        Memories:
        \(memorySummaries)

        Example output: [5, 2, 0, 7]
        """

        let messages = [
            ChatMessage(role: "system", content: "You are a relevance scoring engine. Output ONLY a JSON array of integers."),
            ChatMessage(role: "user", content: prompt)
        ]

        // Use DeepSeek (cheapest) for scoring
        let scorer = OpenAICompatibleService(provider: .deepseek, model: "deepseek-chat")

        guard let response = try? await scorer.sendChatRequest(
            messages: messages, tools: nil, maxTokens: 128
        ), let text = response.text else {
            return Array(candidates.prefix(limit))
        }

        // Parse response — extract JSON array from potentially wrapped text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonStr: String
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]") {
            jsonStr = String(trimmed[start...end])
        } else {
            return Array(candidates.prefix(limit))
        }

        guard let data = jsonStr.data(using: .utf8),
              let indices = try? JSONDecoder().decode([Int].self, from: data) else {
            return Array(candidates.prefix(limit))
        }

        let candidateArray = Array(candidates.prefix(30))
        let reordered = indices.compactMap { i -> MemoryManager.Memory? in
            guard i >= 0, i < candidateArray.count else { return nil }
            return candidateArray[i]
        }

        return Array(reordered.prefix(limit))
    }
}
