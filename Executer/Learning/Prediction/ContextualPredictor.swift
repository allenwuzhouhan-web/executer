import Foundation

/// Embedding-based prediction: finds similar past sessions and predicts based on what happened next.
enum ContextualPredictor {

    /// Predict next likely app based on current session context.
    static func predictNextApp(currentSession: WorkSession, pastSessions: [WorkSession]) -> [(app: String, confidence: Double)] {
        let currentTopics = currentSession.topics.joined(separator: " ")

        var appScores: [String: Double] = [:]

        for past in pastSessions where past.id != currentSession.id {
            let pastTopics = past.topics.joined(separator: " ")
            let similarity = TextEmbedder.textSimilarity(currentTopics, pastTopics)

            guard similarity > 0.3 else { continue }

            // What apps did the user use in this similar session?
            for app in past.apps {
                appScores[app, default: 0] += similarity
            }
        }

        // Remove apps already in current session
        for app in currentSession.apps {
            appScores.removeValue(forKey: app)
        }

        return appScores
            .map { (app: $0.key, confidence: min($0.value, 1.0)) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map { ($0.app, $0.confidence) }
    }
}
