import Foundation

/// Finds analogous past situations using embeddings when facing novel scenarios.
enum SimilarityReasoner {

    /// Find the most similar past session to the current situation.
    static func findSimilarSessions(to currentTopics: Set<String>, from pastSessions: [WorkSession], limit: Int = 5) -> [WorkSession] {
        let currentText = currentTopics.joined(separator: " ")

        var scored: [(session: WorkSession, similarity: Double)] = []

        for session in pastSessions {
            let pastText = session.topics.joined(separator: " ")
            let sim = TextEmbedder.textSimilarity(currentText, pastText)
            if sim > 0.3 {
                scored.append((session, sim))
            }
        }

        return scored.sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map(\.session)
    }

    /// Find templates that were successful in similar situations.
    static func findRelevantTemplates(for topics: Set<String>) -> [WorkflowTemplate] {
        let allTemplates = TemplateLibrary.shared.all()
        return allTemplates.filter { $0.successRate > 0.5 && $0.timesExecuted > 0 }
    }
}
