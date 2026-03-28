import Foundation

/// Generates daily summaries from sessions and observations.
/// Structural assembly only — NO LLM call. Zero cost, zero latency.
enum DailySummaryGenerator {

    /// Generate a summary for the given date from today's sessions.
    static func generate(sessions: [WorkSession], date: Date = Date()) -> DailySummary {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        // Build session summaries
        let sessionSummaries = sessions.map { session -> DailySummary.SessionSummary in
            let keyObs = session.observations
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .map(\.intent)

            return DailySummary.SessionSummary(
                title: session.title,
                apps: session.apps,
                topics: Array(session.topics.sorted().prefix(5)),
                durationSeconds: session.duration,
                startTime: session.startTime,
                keyObservations: Array(keyObs)
            )
        }

        // Build app usage
        var appSessions: [String: (count: Int, topics: [String])] = [:]
        for session in sessions {
            for app in session.apps {
                var entry = appSessions[app] ?? (0, [])
                entry.count += 1
                entry.topics.append(contentsOf: session.topics)
                appSessions[app] = entry
            }
        }
        let appUsage = appSessions.map { (app, data) in
            let topTopic = data.topics.isEmpty ? "general" :
                Dictionary(grouping: data.topics, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key ?? "general"
            return DailySummary.AppUsageEntry(appName: app, sessionCount: data.count, primaryTopic: topTopic)
        }.sorted { $0.sessionCount > $1.sessionCount }

        // Aggregate topics
        var topicFreq: [String: Int] = [:]
        for session in sessions {
            for topic in session.topics {
                topicFreq[topic, default: 0] += 1
            }
        }
        let topTopics = topicFreq.sorted { $0.value > $1.value }.prefix(10).map(\.key)

        // Total actions
        let totalActions = sessions.reduce(0) { $0 + $1.observations.count }

        return DailySummary(
            date: dateString,
            sessionsCount: sessions.count,
            sessions: sessionSummaries,
            appUsage: appUsage,
            topTopics: topTopics,
            totalActions: totalActions
        )
    }
}
