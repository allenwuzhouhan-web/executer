import Foundation

/// Extracts semantic observations from presentation apps (Keynote, PowerPoint, Google Slides).
/// Pays attention to: fonts, colors, layout, slide count, presentation topic.
struct PresentationExtractor: AttentionExtractor {
    var appPatterns: [String] { ["keynote", "powerpoint", "google slides", "impress"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var details: [String: String] = [:]
        var topics: [String] = []

        // Extract font choices from menu actions
        for action in actions where action.type == .menuSelect || action.type == .click {
            let title = action.elementTitle.lowercased()
            if title.contains("font") || action.elementRole == "AXPopUpButton" {
                if !action.elementValue.isEmpty {
                    details["font"] = action.elementValue
                }
            }
        }

        // Extract topics from text edits (what they type into slides)
        let typedTexts = actions.filter { $0.type == .textEdit && !$0.elementValue.isEmpty }
            .map(\.elementValue)
        if !typedTexts.isEmpty {
            topics = NLPipeline.extractTopics(from: typedTexts, limit: 5)
        }

        // Extract from screen text if available
        if let screenText = screenText {
            let allText = screenText.joined(separator: " ")
            // Look for font panel values
            for text in screenText {
                if text.contains("pt") || text.contains("px") {
                    details["fontSize"] = text
                }
            }
            let screenTopics = NLPipeline.extractKeywords(from: allText, limit: 5)
            topics.append(contentsOf: screenTopics)
        }

        // Count slides from window title (e.g., "Slide 5 of 12")
        for action in actions {
            if let match = action.elementTitle.range(of: #"(\d+)\s+of\s+(\d+)"#, options: .regularExpression) {
                details["slideInfo"] = String(action.elementTitle[match])
            }
        }

        guard !topics.isEmpty || !details.isEmpty else { return [] }

        let intent = "Working on presentation" + (topics.isEmpty ? "" : " about \(topics.prefix(3).joined(separator: ", "))")

        return [SemanticObservation(
            appName: appName,
            category: .design,
            intent: intent,
            details: details,
            relatedTopics: Array(Set(topics)),
            confidence: 0.7
        )]
    }
}
