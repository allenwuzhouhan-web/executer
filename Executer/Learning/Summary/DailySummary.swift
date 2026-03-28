import Foundation

/// A daily summary of the user's work, assembled from sessions and observations.
struct DailySummary: Codable {
    let date: String                          // "2026-03-28"
    let sessionsCount: Int
    let sessions: [SessionSummary]
    let appUsage: [AppUsageEntry]
    let topTopics: [String]                   // Top 10 topics of the day
    let totalActions: Int

    struct SessionSummary: Codable {
        let title: String
        let apps: [String]
        let topics: [String]
        let durationSeconds: TimeInterval
        let startTime: Date
        let keyObservations: [String]         // Top 5 observations as one-liners
    }

    struct AppUsageEntry: Codable {
        let appName: String
        let sessionCount: Int
        let primaryTopic: String
    }

    /// Generate a markdown representation for storage.
    func toMarkdown() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE"
        let dayOfWeek = dateFormatter.string(from: ISO8601DateFormatter().date(from: date + "T00:00:00Z") ?? Date())

        var md = "# Daily Summary: \(date) (\(dayOfWeek))\n\n"

        if sessions.isEmpty {
            md += "No significant work sessions recorded.\n"
            return md
        }

        md += "## Sessions\n\n"
        for (i, session) in sessions.enumerated() {
            let mins = Int(session.durationSeconds / 60)
            let duration = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"

            md += "### \(i + 1). \(session.title) (\(duration))\n"
            md += "**Apps:** \(session.apps.joined(separator: " → "))\n"
            if !session.topics.isEmpty {
                md += "**Topics:** \(session.topics.joined(separator: ", "))\n"
            }
            for obs in session.keyObservations {
                md += "- \(obs)\n"
            }
            md += "\n"
        }

        if !appUsage.isEmpty {
            md += "## App Usage\n"
            for entry in appUsage {
                md += "- **\(entry.appName)**: \(entry.sessionCount) session(s) — \(entry.primaryTopic)\n"
            }
            md += "\n"
        }

        if !topTopics.isEmpty {
            md += "## Topics: \(topTopics.joined(separator: ", "))\n"
        }

        return md
    }
}
