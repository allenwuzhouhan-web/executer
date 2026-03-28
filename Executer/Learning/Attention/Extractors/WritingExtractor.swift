import Foundation

/// Extracts semantic observations from writing apps (Pages, Word, Notes, TextEdit).
/// Pays attention to: document topic, writing style, formatting choices.
struct WritingExtractor: AttentionExtractor {
    var appPatterns: [String] { ["pages", "word", "google docs", "textedit", "notes", "notion", "obsidian", "bear", "ulysses", "scrivener", "ia writer"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var topics: [String] = []
        var details: [String: String] = [:]

        // Extract document title from window
        for action in actions where action.type == .windowOpen || action.type == .focus {
            if !action.elementTitle.isEmpty && action.elementTitle.count > 2 {
                details["documentTitle"] = action.elementTitle
                let titleTopics = NLPipeline.extractKeywords(from: action.elementTitle, limit: 3)
                topics.append(contentsOf: titleTopics)
            }
        }

        // Extract topics from typed text
        let typedTexts = actions.filter { $0.type == .textEdit && !$0.elementValue.isEmpty }
            .map(\.elementValue)
        if !typedTexts.isEmpty {
            let textTopics = NLPipeline.extractTopics(from: typedTexts, limit: 5)
            topics.append(contentsOf: textTopics)
        }

        // Formatting choices from menu selections
        for action in actions where action.type == .menuSelect {
            let title = action.elementTitle.lowercased()
            if title.contains("bold") || title.contains("italic") || title.contains("heading") || title.contains("font") {
                details["formatting"] = action.elementTitle
            }
        }

        guard !topics.isEmpty else { return [] }

        var intent = "Writing"
        if let doc = details["documentTitle"] { intent += ": \(doc)" }

        return [SemanticObservation(
            appName: appName,
            category: .writing,
            intent: intent,
            details: details,
            relatedTopics: Array(Set(topics)),
            confidence: 0.7
        )]
    }
}
