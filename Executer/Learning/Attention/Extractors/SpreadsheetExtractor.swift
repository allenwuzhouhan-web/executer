import Foundation

/// Extracts semantic observations from spreadsheet apps (Excel, Numbers, Google Sheets).
/// Pays attention to: data topics, formula usage, analysis type.
struct SpreadsheetExtractor: AttentionExtractor {
    var appPatterns: [String] { ["excel", "numbers", "google sheets", "sheets", "libreoffice calc"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var topics: [String] = []
        var details: [String: String] = [:]

        // Extract from window title (usually the filename)
        for action in actions where action.type == .windowOpen || action.type == .focus {
            if !action.elementTitle.isEmpty {
                details["fileName"] = action.elementTitle
                topics.append(contentsOf: NLPipeline.extractKeywords(from: action.elementTitle, limit: 3))
            }
        }

        // Detect formula usage
        let formulas = actions.filter { $0.type == .textEdit && $0.elementValue.hasPrefix("=") }
        if !formulas.isEmpty {
            details["usesFormulas"] = "true"
            details["formulaCount"] = "\(formulas.count)"
        }

        // Extract topics from visible text
        if let screenText = screenText {
            let sheetTopics = NLPipeline.extractTopics(from: screenText, limit: 5)
            topics.append(contentsOf: sheetTopics)
        }

        guard !topics.isEmpty || !details.isEmpty else { return [] }

        let intent = "Analyzing data" + (topics.isEmpty ? "" : " related to \(topics.prefix(2).joined(separator: ", "))")

        return [SemanticObservation(
            appName: appName,
            category: .dataAnalysis,
            intent: intent,
            details: details,
            relatedTopics: Array(Set(topics)),
            confidence: 0.6
        )]
    }
}
