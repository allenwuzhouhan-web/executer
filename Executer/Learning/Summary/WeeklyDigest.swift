import Foundation

/// Generates weekly learning digests from daily summaries.
struct WeeklySummary: Codable {
    let weekStartDate: String       // "2026-03-23"
    let weekEndDate: String         // "2026-03-29"
    let totalSessions: Int
    let totalActions: Int
    let topApps: [String]           // Ranked by usage
    let topTopics: [String]         // Ranked by frequency
    let workflowsImproved: Int      // Patterns with increased confidence
    let newPatternsDetected: Int
    let daysActive: Int
}

enum WeeklyDigestGenerator {

    /// Generate a weekly summary from daily summary files.
    static func generate(endDate: Date = Date()) -> WeeklySummary? {
        let calendar = Calendar.current
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer/daily_summaries", isDirectory: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var dailySummaries: [DailySummary] = []

        // Load last 7 days of summaries
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: endDate) else { continue }
            let dateStr = dateFormatter.string(from: date)
            let file = dir.appendingPathComponent("\(dateStr).json")

            guard let data = try? Data(contentsOf: file),
                  let summary = try? JSONDecoder().decode(DailySummary.self, from: data) else { continue }
            dailySummaries.append(summary)
        }

        guard !dailySummaries.isEmpty else { return nil }

        // Aggregate
        let totalSessions = dailySummaries.reduce(0) { $0 + $1.sessionsCount }
        let totalActions = dailySummaries.reduce(0) { $0 + $1.totalActions }

        var appFreq: [String: Int] = [:]
        var topicFreq: [String: Int] = [:]

        for summary in dailySummaries {
            for entry in summary.appUsage {
                appFreq[entry.appName, default: 0] += entry.sessionCount
            }
            for topic in summary.topTopics {
                topicFreq[topic, default: 0] += 1
            }
        }

        let startDate = calendar.date(byAdding: .day, value: -6, to: endDate) ?? endDate

        return WeeklySummary(
            weekStartDate: dateFormatter.string(from: startDate),
            weekEndDate: dateFormatter.string(from: endDate),
            totalSessions: totalSessions,
            totalActions: totalActions,
            topApps: appFreq.sorted { $0.value > $1.value }.prefix(10).map(\.key),
            topTopics: topicFreq.sorted { $0.value > $1.value }.prefix(10).map(\.key),
            workflowsImproved: 0,  // TODO: track from pattern confidence changes
            newPatternsDetected: 0, // TODO: track from pattern creation dates
            daysActive: dailySummaries.count
        )
    }

    /// Format as markdown for display.
    static func toMarkdown(_ summary: WeeklySummary) -> String {
        var md = "# Weekly Learning Report (\(summary.weekStartDate) — \(summary.weekEndDate))\n\n"
        md += "**Active days:** \(summary.daysActive)/7\n"
        md += "**Sessions:** \(summary.totalSessions) | **Actions observed:** \(summary.totalActions)\n\n"

        if !summary.topApps.isEmpty {
            md += "## Top Apps\n"
            for app in summary.topApps.prefix(5) { md += "- \(app)\n" }
            md += "\n"
        }

        if !summary.topTopics.isEmpty {
            md += "## Top Topics\n"
            for topic in summary.topTopics.prefix(5) { md += "- \(topic)\n" }
        }

        return md
    }
}
