import Foundation

/// Complete model of the user's work patterns built over 1 week of observation.
struct WorkProfile: Codable {
    var typicalStartTime: String?       // "09:00"
    var typicalEndTime: String?         // "18:00"
    var workDays: [String]              // ["Mon", "Tue", "Wed", "Thu", "Fri"]
    var topApps: [String]               // Ranked by usage
    var communicationStyle: String?     // "formal", "casual", "brief"
    var breakPatterns: [BreakPattern]
    var focusPeriods: [FocusPeriod]
    var lastUpdated: Date

    struct BreakPattern: Codable {
        let typicalTime: String         // "12:00"
        let durationMinutes: Int
        let frequency: Int              // How many times observed
    }

    struct FocusPeriod: Codable {
        let startHour: Int
        let endHour: Int
        let primaryApp: String
        let productivity: Double        // 0.0–1.0
    }

    init() {
        workDays = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        topApps = []
        breakPatterns = []
        focusPeriods = []
        lastUpdated = Date()
    }

    /// Build a profile from daily summaries.
    static func build(from summaries: [DailySummary]) -> WorkProfile {
        var profile = WorkProfile()

        // Analyze app usage
        var appCounts: [String: Int] = [:]
        for summary in summaries {
            for entry in summary.appUsage {
                appCounts[entry.appName, default: 0] += entry.sessionCount
            }
        }
        profile.topApps = appCounts.sorted { $0.value > $1.value }.prefix(10).map(\.key)
        profile.lastUpdated = Date()

        return profile
    }
}
