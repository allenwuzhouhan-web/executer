import Foundation

/// Tracks multi-day goals by grouping related sessions across days.
/// A goal is created when the same topic appears in sessions on 2+ different days.
final class GoalTracker {
    static let shared = GoalTracker()

    private(set) var goals: [Goal] = []
    private let lock = NSLock()

    /// Minimum days a topic must appear to become a goal.
    private let minDaysForGoal = 2
    /// Days without activity before a goal is marked stale.
    private let staleDays = 14

    private init() {
        loadGoals()
    }

    // MARK: - Session Integration

    /// Process a completed session and update goals.
    func processSession(_ session: WorkSession) {
        lock.lock()
        defer { lock.unlock() }

        // Try to find an existing goal that matches this session
        if let idx = goals.firstIndex(where: { $0.isRelated(to: session) && $0.status == .active }) {
            goals[idx].addSession(session)

            // Update deadline from calendar if not already set
            if goals[idx].deadline == nil {
                if let deadline = CalendarCorrelator.shared.findDeadline(forTopics: goals[idx].relatedTopics) {
                    goals[idx].deadline = deadline.date
                    goals[idx].deadlineSource = deadline.eventTitle
                }
            }

            // Recalculate priority
            goals[idx].priority = calculatePriority(goals[idx])
        } else {
            // Create a new goal candidate
            var goal = Goal(topic: session.title, session: session)

            // Check calendar for deadline
            if let deadline = CalendarCorrelator.shared.findDeadline(forTopics: session.topics) {
                goal.deadline = deadline.date
                goal.deadlineSource = deadline.eventTitle
            }

            goal.priority = calculatePriority(goal)
            goals.append(goal)
        }

        // Mark stale goals
        let cutoff = Date().addingTimeInterval(-Double(staleDays) * 86400)
        for i in goals.indices where goals[i].status == .active {
            if goals[i].lastSeen < cutoff {
                goals[i].status = .stale
            }
        }

        // Sort by priority
        goals.sort { $0.priority > $1.priority }

        saveGoals()
    }

    /// Get the top active goals.
    func topGoals(limit: Int = 5) -> [Goal] {
        lock.lock()
        defer { lock.unlock() }
        return Array(goals.filter { $0.status == .active }.prefix(limit))
    }

    /// Get the most relevant goal for the current session.
    func relevantGoal(for session: WorkSession) -> Goal? {
        lock.lock()
        defer { lock.unlock() }
        return goals.first(where: { $0.isRelated(to: session) && $0.status == .active })
    }

    // MARK: - Priority Calculation

    private func calculatePriority(_ goal: Goal) -> Double {
        var score = 0.0

        // Recency: boost goals worked on recently
        let daysSinceLastSeen = Date().timeIntervalSince(goal.lastSeen) / 86400
        score += max(0, 1.0 - (daysSinceLastSeen / 7.0)) * 0.3

        // Frequency: more sessions = more important
        score += min(Double(goal.sessionCount) / 10.0, 1.0) * 0.2

        // Time invested: more time = more important
        let hoursInvested = goal.totalTimeSeconds / 3600
        score += min(hoursInvested / 10.0, 1.0) * 0.2

        // Deadline urgency: closer deadline = higher priority
        if let deadline = goal.deadline {
            let hoursUntilDeadline = deadline.timeIntervalSince(Date()) / 3600
            if hoursUntilDeadline <= 0 {
                score += 0.3  // Past deadline — critical
            } else if hoursUntilDeadline <= 4 {
                score += 0.28
            } else if hoursUntilDeadline <= 24 {
                score += 0.2
            } else if hoursUntilDeadline <= 72 {
                score += 0.1
            }
        }

        return min(score, 1.0)
    }

    // MARK: - Persistence

    private var goalsFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("goals.json")
    }

    private func loadGoals() {
        guard let data = try? Data(contentsOf: goalsFileURL),
              let loaded = try? JSONDecoder().decode([Goal].self, from: data) else { return }
        goals = loaded
        print("[GoalTracker] Loaded \(goals.count) goals")
    }

    private func saveGoals() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        try? data.write(to: goalsFileURL, options: .atomic)
    }

    /// Clear all goals.
    func clearAll() {
        lock.lock()
        goals.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: goalsFileURL)
    }
}
