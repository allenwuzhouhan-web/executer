import Foundation

/// Fallback extractor for any unrecognized app.
/// Extracts: window titles, menu usage, time spent.
struct GenericExtractor: AttentionExtractor {
    // Empty patterns — matches everything as a fallback
    var appPatterns: [String] { [""] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var topics: [String] = []

        // Extract topics from window titles
        for action in actions where action.type == .windowOpen || action.type == .focus {
            if !action.elementTitle.isEmpty {
                let keywords = NLPipeline.extractKeywords(from: action.elementTitle, limit: 3)
                topics.append(contentsOf: keywords)
            }
        }

        // Extract from screen text if available
        if let screenText = screenText {
            let textTopics = NLPipeline.extractTopics(from: screenText, limit: 5)
            topics.append(contentsOf: textTopics)
        }

        // Classify by app name
        let category = TopicClassifier.classifyApp(appName)

        guard !topics.isEmpty else { return [] }

        let intent = "Using \(appName): \(topics.prefix(3).joined(separator: ", "))"

        return [SemanticObservation(
            appName: appName,
            category: category,
            intent: intent,
            relatedTopics: Array(Set(topics)),
            confidence: 0.4
        )]
    }
}
