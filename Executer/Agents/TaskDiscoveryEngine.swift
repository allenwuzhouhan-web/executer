import Foundation

/// Scans all available data sources to discover tasks the overnight agent can work on.
/// Uses existing tools (search_mail, fetch_wechat_messages, query_calendar_events, etc.)
/// as data sources — no new infrastructure needed.
actor TaskDiscoveryEngine {
    static let shared = TaskDiscoveryEngine()

    /// Last discovery time per source (to avoid redundant scans).
    private var lastScanTime: [String: Date] = [:]
    private let scanCooldown: TimeInterval = 1800  // 30 minutes between scans of the same source

    // MARK: - Main Discovery

    /// Scan all sources and return discovered tasks, deduplicated against existing queue.
    func discoverTasks() async -> [OvernightTask] {
        var discovered: [OvernightTask] = []

        // Run all scanners concurrently
        async let emailTasks = scanEmail()
        async let calendarTasks = scanCalendar()
        async let reminderTasks = scanReminders()
        async let goalTasks = scanGoalStack()
        async let fileTasks = scanFileChanges()

        discovered.append(contentsOf: await emailTasks)
        discovered.append(contentsOf: await calendarTasks)
        discovered.append(contentsOf: await reminderTasks)
        discovered.append(contentsOf: await goalTasks)
        discovered.append(contentsOf: await fileTasks)

        // Deduplicate against existing queue
        let existingTitles = Set(OvernightTaskQueue.shared.allTasks().map(\.title))
        discovered = discovered.filter { !existingTitles.contains($0.title) }

        // Sort by priority
        discovered.sort { $0.priority > $1.priority }

        if !discovered.isEmpty {
            print("[TaskDiscovery] Discovered \(discovered.count) new tasks")
        }

        return discovered
    }

    // MARK: - Email Scanner

    private func scanEmail() async -> [OvernightTask] {
        guard shouldScan("email") else { return [] }
        markScanned("email")

        do {
            // Search for unread actionable emails
            let args = "{\"query\": \"is:unread\", \"limit\": 15}"
            let result = try await ToolRegistry.shared.execute(toolName: "search_mail", arguments: args)

            guard !result.isEmpty && !result.contains("No emails found") else { return [] }

            // Parse email results and create tasks for actionable ones
            var tasks: [OvernightTask] = []
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            for line in lines.prefix(10) {
                let lower = line.lowercased()
                // Look for actionable keywords
                let isActionable = ["review", "please", "urgent", "deadline", "asap", "action",
                                    "attached", "update", "respond", "reply", "submit"].contains(where: { lower.contains($0) })

                if isActionable {
                    tasks.append(OvernightTask(
                        source: .email,
                        title: "Email: \(String(line.prefix(80)))",
                        description: line,
                        priority: lower.contains("urgent") ? 0.9 : 0.5,
                        estimatedMinutes: 5
                    ))
                }
            }

            return tasks
        } catch {
            print("[TaskDiscovery] Email scan failed: \(error)")
            return []
        }
    }

    // MARK: - Calendar Scanner

    private func scanCalendar() async -> [OvernightTask] {
        guard shouldScan("calendar") else { return [] }
        markScanned("calendar")

        do {
            // Check events in next 48 hours
            let result = try await ToolRegistry.shared.execute(
                toolName: "query_calendar_events",
                arguments: "{\"hours_ahead\": 48}"
            )

            guard !result.isEmpty && !result.contains("No events") else { return [] }

            var tasks: [OvernightTask] = []
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            for line in lines {
                let lower = line.lowercased()
                // Events with preparation keywords become tasks
                let needsPrep = ["prepare", "deadline", "submit", "presentation", "report",
                                 "meeting", "review"].contains(where: { lower.contains($0) })

                if needsPrep {
                    tasks.append(OvernightTask(
                        source: .calendar,
                        title: "Prepare for: \(String(line.prefix(80)))",
                        description: "Upcoming event requiring preparation: \(line)",
                        priority: 0.7,
                        estimatedMinutes: 15
                    ))
                }
            }

            return tasks
        } catch {
            print("[TaskDiscovery] Calendar scan failed: \(error)")
            return []
        }
    }

    // MARK: - Reminders Scanner

    private func scanReminders() async -> [OvernightTask] {
        guard shouldScan("reminders") else { return [] }
        markScanned("reminders")

        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: "query_reminders",
                arguments: "{\"completed\": false}"
            )

            guard !result.isEmpty && !result.contains("No reminders") else { return [] }

            var tasks: [OvernightTask] = []
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            for line in lines.prefix(10) {
                tasks.append(OvernightTask(
                    source: .reminder,
                    title: "Reminder: \(String(line.prefix(80)))",
                    description: line,
                    priority: 0.4,
                    estimatedMinutes: 10
                ))
            }

            return tasks
        } catch {
            print("[TaskDiscovery] Reminders scan failed: \(error)")
            return []
        }
    }

    // MARK: - Goal Stack Scanner

    private func scanGoalStack() async -> [OvernightTask] {
        guard shouldScan("goals") else { return [] }
        markScanned("goals")

        let goals = await GoalStack.shared.activeGoals()
        var tasks: [OvernightTask] = []

        for goal in goals.prefix(5) {
            // Find pending sub-goals
            let pendingSubGoals = goal.subGoals.filter { $0.state == .pending }
            for subGoal in pendingSubGoals.prefix(3) {
                // Check if we have a workflow for this
                let hasWorkflow = await WorkflowRepository.shared.search(query: subGoal.title, limit: 1).first != nil

                tasks.append(OvernightTask(
                    source: .goalStack,
                    title: "\(goal.title): \(subGoal.title)",
                    description: goal.description,
                    actionPlan: hasWorkflow ? "Execute matching workflow" : "Use LLM to complete",
                    priority: goal.priority,
                    estimatedMinutes: 10
                ))
            }
        }

        return tasks
    }

    // MARK: - File Change Scanner

    private func scanFileChanges() async -> [OvernightTask] {
        guard shouldScan("files") else { return [] }
        markScanned("files")

        // Check for new files in Downloads that might need organizing
        let downloadsPath = NSHomeDirectory() + "/Downloads"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: downloadsPath) else { return [] }

        let sixHoursAgo = Date().addingTimeInterval(-6 * 3600)
        var tasks: [OvernightTask] = []

        for filename in contents where !filename.hasPrefix(".") {
            let path = downloadsPath + "/" + filename
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > sixHoursAgo else { continue }

            let ext = (filename as NSString).pathExtension.lowercased()
            // Only organize document-type files
            if ["pdf", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "txt", "csv", "zip"].contains(ext) {
                tasks.append(OvernightTask(
                    source: .fileChange,
                    title: "Organize: \(filename)",
                    description: "New file in Downloads: \(filename) (\(ext))",
                    priority: 0.3,
                    estimatedMinutes: 2
                ))
            }
        }

        return Array(tasks.prefix(10))  // Cap at 10 file tasks
    }

    // MARK: - Scan Throttling

    private func shouldScan(_ source: String) -> Bool {
        guard let lastTime = lastScanTime[source] else { return true }
        return Date().timeIntervalSince(lastTime) >= scanCooldown
    }

    private func markScanned(_ source: String) {
        lastScanTime[source] = Date()
    }

    /// Reset scan timers (force immediate re-scan on next discovery pass).
    func resetScanTimers() {
        lastScanTime.removeAll()
    }
}
