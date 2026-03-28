import Foundation

/// Protocol for per-app semantic extractors.
/// Each extractor knows what to pay attention to in a specific app category.
protocol AttentionExtractor {
    /// App name patterns this extractor handles (matched case-insensitively).
    var appPatterns: [String] { get }

    /// Extract semantic observations from a batch of actions and optional screen text.
    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation]
}

/// Routes actions to the correct per-app extractor.
enum AttentionRouter {

    private static let extractors: [AttentionExtractor] = [
        PresentationExtractor(),
        BrowserExtractor(),
        CodeEditorExtractor(),
        AIToolExtractor(),
        WritingExtractor(),
        SpreadsheetExtractor(),
        CommunicationExtractor(),
        GenericExtractor(),  // Fallback — must be last
    ]

    /// Route actions to the correct extractor and return observations.
    static func route(actions: [UserAction], appName: String, screenText: [String]? = nil) -> [SemanticObservation] {
        let lowerApp = appName.lowercased()

        for extractor in extractors {
            if extractor.appPatterns.contains(where: { lowerApp.contains($0) }) {
                return extractor.extract(actions: actions, screenText: screenText, appName: appName)
            }
        }

        // Should never reach here (GenericExtractor matches everything)
        return GenericExtractor().extract(actions: actions, screenText: screenText, appName: appName)
    }
}
