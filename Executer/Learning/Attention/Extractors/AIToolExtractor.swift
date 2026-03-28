import Foundation

/// Extracts semantic observations from AI tools (ChatGPT web, Claude web, Copilot).
/// Pays attention to: what the user is prompting about, conversation topics.
struct AIToolExtractor: AttentionExtractor {
    var appPatterns: [String] { ["chatgpt", "claude", "copilot", "perplexity", "gemini", "bard", "openai", "anthropic"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var topics: [String] = []

        // Extract from text edits (user prompts)
        let prompts = actions.filter { $0.type == .textEdit && !$0.elementValue.isEmpty }
            .map(\.elementValue)

        if !prompts.isEmpty {
            topics = NLPipeline.extractTopics(from: prompts, limit: 5)
        }

        // Extract from screen text (conversation content)
        if let screenText = screenText, topics.isEmpty {
            topics = NLPipeline.extractTopics(from: screenText, limit: 5)
        }

        guard !topics.isEmpty else { return [] }

        let intent = "Using AI for: \(topics.prefix(3).joined(separator: ", "))"

        return [SemanticObservation(
            appName: appName,
            category: .research,
            intent: intent,
            relatedTopics: topics,
            confidence: 0.6
        )]
    }
}
