import Foundation

/// A multi-day goal inferred from recurring work sessions on the same topic.
/// Example: "Q4 Board Deck" detected from 4 consecutive days of Keynote + research sessions.
struct Goal: Codable, Identifiable {
    let id: UUID
    var topic: String                    // "Q4 Board Deck"
    var description: String              // "Preparing presentation for Q4 board meeting"
    var relatedTopics: Set<String>       // All topics across sessions
    var sessionCount: Int                // Number of sessions contributing to this goal
    var totalTimeSeconds: TimeInterval   // Accumulated work time
    var status: GoalStatus
    var deadline: Date?                  // From calendar correlation
    var deadlineSource: String?          // "Board Meeting" (calendar event title)
    var priority: Double                 // Computed: 0.0 (low) to 1.0 (critical)
    var firstSeen: Date
    var lastSeen: Date

    enum GoalStatus: String, Codable {
        case active
        case completed
        case stale       // No session in 14 days
    }

    init(topic: String, session: WorkSession) {
        self.id = UUID()
        self.topic = topic
        self.description = session.title
        self.relatedTopics = session.topics
        self.sessionCount = 1
        self.totalTimeSeconds = session.duration
        self.status = .active
        self.deadline = nil
        self.deadlineSource = nil
        self.priority = 0.3
        self.firstSeen = session.startTime
        self.lastSeen = session.endTime
    }

    /// Add a session to this goal.
    mutating func addSession(_ session: WorkSession) {
        sessionCount += 1
        totalTimeSeconds += session.duration
        relatedTopics.formUnion(session.topics)
        lastSeen = max(lastSeen, session.endTime)
        // Update description from most recent session
        description = session.title
    }

    /// Check if a session is related to this goal.
    func isRelated(to session: WorkSession) -> Bool {
        let intersection = relatedTopics.intersection(session.topics)
        let union = relatedTopics.union(session.topics)
        guard !union.isEmpty else { return false }
        return Double(intersection.count) / Double(union.count) >= 0.40
    }

    /// Formatted total time.
    var totalTimeFormatted: String {
        let hours = Int(totalTimeSeconds / 3600)
        let mins = Int(totalTimeSeconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// Brief summary for prompt injection.
    func summary() -> String {
        var s = "- **\(topic)** (\(totalTimeFormatted) over \(sessionCount) sessions)"
        if let deadline = deadline, let source = deadlineSource {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: deadline, relativeTo: Date())
            s += " — deadline \(relative) (\(source))"
        }
        return s
    }
}

/// Intent annotation linking a session to its inferred motivation.
struct IntentAnnotation: Codable {
    let sessionId: UUID
    let goalId: UUID?
    let intentType: IntentType
    let confidence: Double
    let calendarEventTitle: String?
    let description: String

    enum IntentType: String, Codable {
        case preparing     // Working toward a deadline/event
        case debugging     // Fixing an issue
        case researching   // Gathering information
        case communicating // Exchanging messages
        case reviewing     // Reviewing/editing existing work
        case creating      // Building something new
        case routine       // Regular recurring task
    }
}
