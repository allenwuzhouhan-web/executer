import Foundation

/// Consumes Project Mind Map + Radar signals + time context → outputs prioritized task queue.
/// Replaces hardcoded job discovery with LLM-driven autonomous goal discovery.
actor IntentEngine {
    static let shared = IntentEngine()

    private let discoveryInterval: TimeInterval = 1800  // 30 min
    private var lastDiscoveryTime: Date = .distantPast

    // MARK: - Task Discovery (replaces TaskDiscoveryEngine scanners)

    /// Discover tasks using LLM reasoning over projects, signals, goals, and time.
    /// Returns OvernightTask array compatible with existing queue.
    func discoverTasks() async -> [OvernightTask] {
        // Gather context from all pillars
        let projects = await ProjectMindMap.shared.activeProjects()
        let signals = await InformationRadar.shared.recentSignals(limit: 30)
        let goals = await GoalStack.shared.activeGoals()

        // If we have no context at all, fall back to basic scanners
        guard !projects.isEmpty || !signals.isEmpty || !goals.isEmpty else {
            print("[IntentEngine] No context available, falling back to basic discovery")
            return await fallbackDiscovery()
        }

        let prompt = IntentPromptBuilder.buildDiscoveryPrompt(
            projects: projects,
            signals: signals,
            goals: goals,
            currentTime: Date()
        )

        do {
            let llmResponse = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 2048
            )
            let response = llmResponse.text ?? ""

            let tasks = parseLLMTasks(response)
            print("[IntentEngine] LLM discovered \(tasks.count) tasks")

            // Deduplicate against existing queue
            let existingTitles = Set(OvernightTaskQueue.shared.allTasks().map(\.title))
            let filtered = tasks.filter { !existingTitles.contains($0.title) }

            return filtered
        } catch {
            print("[IntentEngine] LLM discovery failed: \(error), falling back")
            return await fallbackDiscovery()
        }
    }

    /// Dynamic job generation — replaces hardcoded 4-job sequence in OvernightJobRunner.
    func generateJobs() async -> [DynamicJob] {
        let projects = await ProjectMindMap.shared.activeProjects()
        let signals = await InformationRadar.shared.recentSignals(limit: 50)
        let goals = await GoalStack.shared.activeGoals()

        var jobs: [DynamicJob] = []

        // Always run email digest if there are email signals
        let emailSignals = signals.filter { $0.source == .email }
        if !emailSignals.isEmpty {
            jobs.append(DynamicJob(
                name: "Email Digest",
                runner: { await OvernightJobRunner.runEmailDigest() }
            ))
        }

        // File org if there are file signals or Downloads has recent files
        let fileSignals = signals.filter { $0.source == .file }
        if !fileSignals.isEmpty || hasRecentDownloads() {
            jobs.append(DynamicJob(
                name: "File Organization",
                runner: { await OvernightJobRunner.runFileOrganization() }
            ))
        }

        // Calendar prep if calendar signals exist
        let calendarSignals = signals.filter { $0.source == .calendar }
        if !calendarSignals.isEmpty {
            jobs.append(DynamicJob(
                name: "Calendar Prep",
                runner: { await OvernightJobRunner.runCalendarPrep() }
            ))
        }

        // Research if goals have research items
        let researchGoals = goals.filter {
            let lower = ($0.title + " " + $0.description).lowercased()
            return lower.contains("research") || lower.contains("find") || lower.contains("investigate")
        }
        if !researchGoals.isEmpty {
            jobs.append(DynamicJob(
                name: "Research Tasks",
                runner: { await OvernightJobRunner.runResearchTasks() }
            ))
        }

        // Project-specific tasks for incomplete high-priority projects
        for project in projects.prefix(3) where project.completionEstimate < 0.8 {
            let deadlines = project.deadlines.filter { !$0.completed }
            if let upcoming = deadlines.first(where: { $0.date.timeIntervalSinceNow < 172800 }) {
                // Deadline within 48 hours — generate prep job
                jobs.append(DynamicJob(
                    name: "Prepare: \(project.name) — \(upcoming.title)",
                    runner: { await Self.runProjectPrep(projectName: project.name) }
                ))
            }
        }

        print("[IntentEngine] Generated \(jobs.count) dynamic jobs")
        return jobs
    }

    // MARK: - Helpers

    private func parseLLMTasks(_ response: String) -> [OvernightTask] {
        // 5-layer JSON extraction (per project convention)
        let jsonStr: String
        if let range = response.range(of: "[", options: .literal),
           let endRange = response.range(of: "]", options: .backwards) {
            jsonStr = String(response[range.lowerBound...endRange.lowerBound])
        } else {
            return []
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict -> OvernightTask? in
            guard let title = dict["title"] as? String,
                  let description = dict["description"] as? String else { return nil }

            let sourceStr = dict["source"] as? String ?? "manual"
            let source = OvernightTask.TaskSource(rawValue: sourceStr) ?? .manual
            let priority = dict["priority"] as? Double ?? 0.5
            let minutes = dict["estimated_minutes"] as? Int ?? 10

            return OvernightTask(
                source: source,
                title: title,
                description: description,
                priority: priority,
                estimatedMinutes: minutes
            )
        }
    }

    private func fallbackDiscovery() async -> [OvernightTask] {
        // Lightweight fallback: scan file changes and goals without LLM
        var tasks: [OvernightTask] = []

        // Check Downloads for recent files
        let downloadsPath = NSHomeDirectory() + "/Downloads"
        let fm = FileManager.default
        let sixHoursAgo = Date().addingTimeInterval(-6 * 3600)

        if let contents = try? fm.contentsOfDirectory(atPath: downloadsPath) {
            for filename in contents.prefix(10) where !filename.hasPrefix(".") {
                let path = downloadsPath + "/" + filename
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mod = attrs[.modificationDate] as? Date,
                   mod > sixHoursAgo {
                    let ext = (filename as NSString).pathExtension.lowercased()
                    if ["pdf", "docx", "xlsx", "pptx", "txt", "csv"].contains(ext) {
                        tasks.append(OvernightTask(
                            source: .fileChange,
                            title: "Organize: \(filename)",
                            description: "New \(ext) file in Downloads",
                            priority: 0.3,
                            estimatedMinutes: 2
                        ))
                    }
                }
            }
        }

        // Check active goals
        let goals = await GoalStack.shared.activeGoals()
        for goal in goals.prefix(3) {
            let pending = goal.subGoals.filter { $0.state == .pending }
            for sub in pending.prefix(2) {
                tasks.append(OvernightTask(
                    source: .goalStack,
                    title: "\(goal.title): \(sub.title)",
                    description: goal.description,
                    priority: goal.priority,
                    estimatedMinutes: 10
                ))
            }
        }

        return tasks
    }

    private func hasRecentDownloads() -> Bool {
        let fm = FileManager.default
        let path = NSHomeDirectory() + "/Downloads"
        let sixHours = Date().addingTimeInterval(-6 * 3600)
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return false }
        return contents.contains { name in
            !name.hasPrefix(".") &&
            (try? fm.attributesOfItem(atPath: path + "/" + name))?[.modificationDate] as? Date ?? .distantPast > sixHours
        }
    }

    private static func runProjectPrep(projectName: String) async -> JobResult {
        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: "find_files",
                arguments: "{\"query\": \"\(projectName)\", \"limit\": 10}"
            )
            return JobResult(
                name: "Project Prep: \(projectName)",
                status: .completed,
                summary: "Found related files for \(projectName)",
                actions: ["Searched for project files"],
                outputPath: nil
            )
        } catch {
            return JobResult(
                name: "Project Prep: \(projectName)",
                status: .failed,
                summary: "Failed: \(error.localizedDescription)",
                actions: [],
                outputPath: nil
            )
        }
    }
}

/// A dynamically generated overnight job.
struct DynamicJob {
    let name: String
    let runner: () async -> JobResult
}
