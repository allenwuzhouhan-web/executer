import Foundation

/// Schedules daily summary generation.
/// Checks every 15 minutes after 10 PM, or on next-day launch.
final class SummaryScheduler {
    static let shared = SummaryScheduler()

    private var timer: Timer?
    private let summaryHour = 22  // 10 PM

    private init() {}

    /// Start the scheduler. Call from LearningManager.start().
    func start() {
        // Check if yesterday's summary is missing (app was closed overnight)
        generateIfNeeded()

        // Schedule periodic checks
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.generateIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Generate today's summary if it's past the summary hour and hasn't been generated yet.
    func generateIfNeeded() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)

        guard hour >= summaryHour || hour < 5 else { return }  // Only after 10 PM or before 5 AM

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: now)

        // Check if summary already exists for today
        // (In Phase 0 we don't have the summaries table yet, so this is a placeholder)
        // TODO: Check LearningDatabase for existing summary

        let sessions = SessionDetector.shared.todaysSessions()
        guard !sessions.isEmpty else { return }

        let summary = DailySummaryGenerator.generate(sessions: sessions)

        // Store the summary
        saveSummary(summary)

        print("[SummaryScheduler] Generated daily summary for \(today): \(summary.sessionsCount) sessions, \(summary.totalActions) actions")
    }

    /// Force generate a summary for today (for testing or manual trigger).
    func generateNow() {
        let sessions = SessionDetector.shared.todaysSessions()
        let summary = DailySummaryGenerator.generate(sessions: sessions)
        saveSummary(summary)
    }

    private func saveSummary(_ summary: DailySummary) {
        // Save markdown file
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer/daily_summaries", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = dir.appendingPathComponent("\(summary.date).md")
        try? summary.toMarkdown().write(to: file, atomically: true, encoding: .utf8)

        // Also save JSON for structured queries
        let jsonFile = dir.appendingPathComponent("\(summary.date).json")
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: jsonFile, options: .atomic)
        }
    }
}
