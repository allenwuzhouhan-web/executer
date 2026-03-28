import Foundation

/// Extracts semantic observations from browsers (Safari, Chrome, Arc, Firefox).
/// Pays attention to: search queries, visited domains, research topics, tab titles.
struct BrowserExtractor: AttentionExtractor {
    var appPatterns: [String] { ["safari", "chrome", "firefox", "arc", "edge", "brave", "opera"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var topics: [String] = []
        var details: [String: String] = [:]
        var searchQueries: [String] = []

        for action in actions {
            // URL bar / search field edits
            if action.type == .textEdit &&
               (action.elementRole == "AXTextField" || action.elementTitle.lowercased().contains("address") || action.elementTitle.lowercased().contains("search")) {
                let query = action.elementValue
                if !query.isEmpty && !query.hasPrefix("http") {
                    searchQueries.append(query)
                }
                if query.contains("://") {
                    // Extract domain
                    if let url = URL(string: query), let host = url.host {
                        details["domain"] = host
                    }
                }
            }

            // Tab/window titles contain page titles
            if action.type == .windowOpen || action.type == .focus {
                let title = action.elementTitle
                if !title.isEmpty && title.count > 3 {
                    let keywords = NLPipeline.extractKeywords(from: title, limit: 3)
                    topics.append(contentsOf: keywords)
                }
            }
        }

        // Extract topics from search queries
        if !searchQueries.isEmpty {
            let queryTopics = NLPipeline.extractTopics(from: searchQueries, limit: 5)
            topics.append(contentsOf: queryTopics)
            details["recentSearch"] = searchQueries.last ?? ""
        }

        guard !topics.isEmpty else { return [] }

        let intent = "Browsing/researching: \(Array(Set(topics)).prefix(3).joined(separator: ", "))"

        return [SemanticObservation(
            appName: appName,
            category: .research,
            intent: intent,
            details: details,
            relatedTopics: Array(Set(topics)),
            confidence: 0.6
        )]
    }
}
