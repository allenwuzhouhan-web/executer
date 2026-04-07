import Foundation

// MARK: - Core Belief

struct Belief: Identifiable, Sendable {
    let id: Int
    let patternType: PatternType
    let description: String
    let patternData: String       // JSON blob — decoded on demand per pattern type
    var confidence: Double
    var classification: BeliefClassification
    let firstObserved: String     // YYYY-MM-DD
    var lastObserved: String      // YYYY-MM-DD
    var observationCount: Int
    var distinctDays: Int
    var vetoed: Bool
    var boosted: Bool
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Pattern-Specific Data (stored as JSON in pattern_data column)

struct AppUsagePattern: Codable, Sendable {
    let bundleId: String
    let appName: String
    var avgDailyMinutes: Double
    var typicalHours: [Int]       // hours of day when typically used
    var typicalDays: [Int]        // days of week (1=Mon..7=Sun)
    var totalSessions: Int
}

struct WorkflowSequencePattern: Codable, Sendable {
    struct Step: Codable, Sendable {
        let app: String           // bundle ID or app name
        let context: String       // window title or domain
    }
    let steps: [Step]
    var avgDurationSeconds: Double
    var typicalHour: Int?
    var typicalDay: Int?
}

struct TemporalRoutinePattern: Codable, Sendable {
    let hourStart: Int            // e.g., 21
    let hourEnd: Int              // e.g., 22
    var daysOfWeek: [Int]
    let dominantApp: String
    let dominantActivity: String  // "browsing ManageBac", "coding in Xcode"
}

struct ProjectClusterPattern: Codable, Sendable {
    var clusterName: String       // auto-derived most distinctive term
    var apps: [String]
    var domains: [String]
    var fileExtensions: [String]
    var directories: [String]
    var coOccurrenceRate: Double   // fraction of days these items appear together
}

struct CommunicationPattern: Codable, Sendable {
    let contactName: String
    let platform: String          // "WeChat", "iMessage", "Mail", "Slack"
    var typicalHours: [Int]
    var frequency: String         // "daily", "weekly", "occasional"
    var typicalLanguage: String?  // "zh", "en"
    var messageCount: Int
}

struct PreferencePattern: Codable, Sendable {
    let category: String          // "appearance", "language", "workflow_style", "tools"
    let key: String               // "dark_mode", "primary_coding_language"
    let value: String             // "true", "Swift"
    var evidenceCount: Int
}

// MARK: - Query Result Types

struct ProjectContext: Sendable {
    let projectName: String
    let apps: [String]
    let domains: [String]
    let confidence: Double
}

struct RoutineExpectation: Sendable {
    let description: String
    let dominantApp: String
    let confidence: Double
}

struct StuckAssessment: Sendable {
    let isStuck: Bool
    let confidence: Double
    let evidence: String          // "repeated searches", "same file 30+ min"
}

struct UserKnowledgeReport: Sendable {
    let beliefs: [Belief]
    let hypotheses: [Belief]
    let totalObservations: Int
    let oldestObservation: String?
    let newestObservation: String?
}

// MARK: - Correction

struct BeliefCorrection: Sendable {
    let beliefId: Int
    let correctionType: CorrectionType
    let userStatement: String?
    let timestamp: Date

    enum CorrectionType: String, Sendable {
        case veto   // "that's not a pattern"
        case boost  // "yes, I always do that"
    }
}
