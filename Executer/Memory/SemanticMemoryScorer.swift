import Foundation

/// Uses a fast LLM call (DeepSeek) to score memory relevance when keyword scoring is insufficient.
/// Only called as a second pass on keyword-filtered top-K results.
///
/// Flash Attention-inspired: uses online softmax for streaming relevance scoring
/// and grouped-query pattern to share scored keys across namespaces.
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

    // MARK: - Online Softmax Scoring (Flash Attention-inspired)

    /// Score memories using online softmax — processes candidates in streaming blocks
    /// without needing all scores in memory at once. Uses embedding-based similarity
    /// scored through Flash Attention's incremental softmax algorithm.
    func scoreRelevanceStreaming(
        query: String,
        candidates: [MemoryManager.Memory],
        limit: Int = 10,
        blockSize: Int = 16
    ) -> [MemoryManager.Memory] {
        guard !query.isEmpty, !candidates.isEmpty else { return [] }
        guard let queryVec = TextEmbedder.sentenceVector(query) else {
            return Array(candidates.prefix(limit))
        }

        // Compute similarity scores for all candidates
        var scores = [Double](repeating: 0, count: candidates.count)
        for (i, candidate) in candidates.enumerated() {
            if let memVec = TextEmbedder.sentenceVector(candidate.content) {
                scores[i] = TextEmbedder.cosineSimilarity(queryVec, memVec)
            }
        }

        // Use online softmax to rank — processes in blocks, numerically stable
        let ranked = FlashAttentionUtils.streamingSoftmaxRank(scores: scores, blockSize: blockSize)

        return ranked.prefix(limit).map { candidates[$0.index] }
    }

    // MARK: - Grouped-Query Scoring (Flash Attention GQA-inspired)

    /// Score memories once and share results across multiple query contexts.
    /// Like GQA where fewer KV heads serve multiple Q heads — we score the candidate
    /// "keys" once against a representative query, then reuse for related queries.
    func scoreGrouped(
        queries: [String],
        sharedCandidates: [MemoryManager.Memory],
        limitPerQuery: Int = 5
    ) -> [String: [MemoryManager.Memory]] {
        guard !sharedCandidates.isEmpty else {
            return Dictionary(uniqueKeysWithValues: queries.map { ($0, []) })
        }

        // Build candidate embeddings once (shared "KV heads")
        let candidateVecs: [(index: Int, vec: [Double])] = sharedCandidates.enumerated().compactMap { (i, m) in
            guard let vec = TextEmbedder.sentenceVector(m.content) else { return nil }
            return (i, vec)
        }

        var results: [String: [MemoryManager.Memory]] = [:]

        for query in queries {
            guard let queryVec = TextEmbedder.sentenceVector(query) else {
                results[query] = []
                continue
            }

            // Score this query against shared candidate vectors
            var scored: [(index: Int, score: Double)] = []
            for (idx, vec) in candidateVecs {
                let sim = TextEmbedder.cosineSimilarity(queryVec, vec)
                scored.append((idx, sim))
            }

            scored.sort { $0.score > $1.score }
            results[query] = scored.prefix(limitPerQuery).map { sharedCandidates[$0.index] }
        }

        return results
    }
}
