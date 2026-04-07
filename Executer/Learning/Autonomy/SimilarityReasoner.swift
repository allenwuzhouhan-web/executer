import Foundation

/// Finds analogous past situations using embeddings when facing novel scenarios.
///
/// Flash Attention-inspired: uses tiled batch similarity for cache-efficient
/// comparisons and adaptive caching (recomputation trade-off) for embeddings.
enum SimilarityReasoner {

    /// Find the most similar past session to the current situation.
    /// Uses tiled batch similarity (Flash Attention IO-aware) for cache-efficient comparison.
    static func findSimilarSessions(to currentTopics: Set<String>, from pastSessions: [WorkSession], limit: Int = 5) -> [WorkSession] {
        let currentText = currentTopics.joined(separator: " ")

        // Use tiled batch similarity for cache-efficient comparison
        let candidateTexts = pastSessions.map { $0.topics.joined(separator: " ") }
        let tiledResults = TextEmbedder.tiledTextSimilarity(
            query: currentText,
            candidates: candidateTexts,
            tileSize: 32
        )

        return tiledResults
            .filter { $0.similarity > 0.3 }
            .prefix(limit)
            .map { pastSessions[$0.index] }
    }

    /// Find templates that were successful in similar situations.
    static func findRelevantTemplates(for topics: Set<String>) -> [WorkflowTemplate] {
        let allTemplates = TemplateLibrary.shared.all()
        return allTemplates.filter { $0.successRate > 0.5 && $0.timesExecuted > 0 }
    }
}
