import Foundation

/// A semantic observation extracted from raw user actions.
/// Unlike UserAction (mechanical), this captures MEANING:
/// what the user is doing, not just what they clicked.
struct SemanticObservation: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let category: TopicClassifier.Topic
    let intent: String              // "Creating presentation with minimalist design"
    let details: [String: String]   // ["font": "Helvetica", "colorPalette": "navy+white"]
    let relatedTopics: [String]     // ["pitch deck", "product launch"]
    let entities: [EntityExtractor.Entity]
    let confidence: Double          // 0.0–1.0

    init(appName: String, category: TopicClassifier.Topic, intent: String,
         details: [String: String] = [:], relatedTopics: [String] = [],
         entities: [EntityExtractor.Entity] = [], confidence: Double = 0.5) {
        self.id = UUID()
        self.timestamp = Date()
        self.appName = appName
        self.category = category
        self.intent = intent
        self.details = details
        self.relatedTopics = relatedTopics
        self.entities = entities
        self.confidence = confidence
    }
}
