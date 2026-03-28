import Foundation

/// A coherent work session spanning one or more apps, grouped by topic similarity.
/// Example: "Q1 Revenue Report Preparation" spanning Safari → Excel → Pages.
struct WorkSession: Codable, Identifiable {
    let id: UUID
    var title: String                          // Auto-generated: "Q1 Revenue Report Preparation"
    var topics: Set<String>                    // Union of all relatedTopics
    var apps: [String]                         // Ordered list of apps used
    var observations: [SemanticObservation]    // All observations in this session
    var startTime: Date
    var endTime: Date
    var isActive: Bool

    init(observation: SemanticObservation) {
        self.id = UUID()
        self.title = observation.intent
        self.topics = Set(observation.relatedTopics)
        self.apps = [observation.appName]
        self.observations = [observation]
        self.startTime = observation.timestamp
        self.endTime = observation.timestamp
        self.isActive = true
    }

    /// Add an observation to this session.
    mutating func addObservation(_ observation: SemanticObservation) {
        observations.append(observation)
        topics.formUnion(observation.relatedTopics)
        endTime = observation.timestamp
        if !apps.contains(observation.appName) {
            apps.append(observation.appName)
        }
        // Update title from the most recent high-confidence observation
        if observation.confidence > 0.5 {
            title = observation.intent
        }
    }

    /// Duration of the session.
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Formatted duration string.
    var durationFormatted: String {
        let minutes = Int(duration / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    /// Brief summary for prompt injection.
    func summary() -> String {
        var lines = ["### \(title) (\(durationFormatted))"]
        lines.append("Apps: \(apps.joined(separator: " → "))")
        if !topics.isEmpty {
            lines.append("Topics: \(topics.sorted().prefix(5).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
