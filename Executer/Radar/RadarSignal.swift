import Foundation

/// Normalized signal emitted by the Information Radar from any source.
struct RadarSignal: Codable, Identifiable, Sendable {
    let id: UUID
    let source: SignalSource
    let type: SignalType
    let title: String
    let body: String
    var relevantProjectId: UUID?
    let urgency: Double             // 0.0–1.0
    let timestamp: Date

    enum SignalSource: String, Codable, Sendable {
        case email, calendar, news, file, reminder, web
    }

    enum SignalType: String, Codable, Sendable {
        case deadlineChange, newTask, urgent, info
        case newEmail, eventReminder, fileCreated, newsUpdate
    }

    init(
        source: SignalSource,
        type: SignalType,
        title: String,
        body: String,
        urgency: Double = 0.3,
        relevantProjectId: UUID? = nil
    ) {
        self.id = UUID()
        self.source = source
        self.type = type
        self.title = title
        self.body = body
        self.urgency = min(1.0, max(0.0, urgency))
        self.relevantProjectId = relevantProjectId
        self.timestamp = Date()
    }
}
