import Foundation

/// Executes concrete overnight jobs: email digest, file organization,
/// calendar prep, and research tasks. Each job produces tangible output
/// files in the G8 workspace.
enum OvernightJobRunner {

    /// Run all overnight jobs sequentially. Returns a structured result.
    static func runAllJobs() async -> JobRunResult {
        let startTime = Date()
        var results: [JobResult] = []

        print("[OvernightJobs] Starting all jobs")

        // Job 1: Email Digest
        let emailResult = await runEmailDigest()
        results.append(emailResult)

        // Job 2: File Organization
        let fileResult = await runFileOrganization()
        results.append(fileResult)

        // Job 3: Calendar Prep
        let calendarResult = await runCalendarPrep()
        results.append(calendarResult)

        // Job 4: Research Tasks
        let researchResult = await runResearchTasks()
        results.append(researchResult)

        let duration = Date().timeIntervalSince(startTime)
        print("[OvernightJobs] All jobs complete in \(Int(duration))s")

        return JobRunResult(
            jobs: results,
            totalDuration: duration,
            startTime: startTime
        )
    }

    // MARK: - Job 1: Email Digest

    static func runEmailDigest() async -> JobResult {
        print("[OvernightJobs] Running email digest...")
        var actions: [String] = []
        var emailCount = 0

        do {
            // Search for unread emails
            let searchResult = try await ToolRegistry.shared.execute(
                toolName: "search_mail",
                arguments: "{\"query\": \"is:unread\", \"limit\": 20}"
            )

            guard !searchResult.contains("No emails found") && !searchResult.isEmpty else {
                return JobResult(name: "Email Digest", status: .completed,
                                summary: "No unread emails", actions: [], outputPath: nil)
            }

            // Parse emails and build digest
            let lines = searchResult.components(separatedBy: "\n").filter { !$0.isEmpty }
            emailCount = lines.count

            var digestLines: [String] = []
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            digestLines.append("# Email Digest — \(formatter.string(from: Date()))")
            digestLines.append("")
            digestLines.append("**\(emailCount) unread emails found**")
            digestLines.append("")

            // Categorize by urgency keywords
            var urgent: [String] = []
            var actionNeeded: [String] = []
            var fyi: [String] = []

            for line in lines {
                let lower = line.lowercased()
                if lower.contains("urgent") || lower.contains("asap") || lower.contains("deadline") {
                    urgent.append(line)
                } else if lower.contains("please") || lower.contains("review") || lower.contains("action") || lower.contains("respond") {
                    actionNeeded.append(line)
                } else {
                    fyi.append(line)
                }
            }

            if !urgent.isEmpty {
                digestLines.append("## Urgent (\(urgent.count))")
                for email in urgent { digestLines.append("- \(email)") }
                digestLines.append("")
            }
            if !actionNeeded.isEmpty {
                digestLines.append("## Action Needed (\(actionNeeded.count))")
                for email in actionNeeded { digestLines.append("- \(email)") }
                digestLines.append("")
            }
            if !fyi.isEmpty {
                digestLines.append("## FYI (\(fyi.count))")
                for email in fyi { digestLines.append("- \(email)") }
            }

            // Write digest file
            let workspace = WorkspaceConfig.shared.workspaceRoot
            let digestPath = workspace + "/Email Digest \(formatter.string(from: Date())).md"
            try digestLines.joined(separator: "\n").write(
                toFile: digestPath, atomically: true, encoding: .utf8
            )
            actions.append("Wrote email digest to G8 folder")

            return JobResult(name: "Email Digest", status: .completed,
                            summary: "\(emailCount) emails digested (\(urgent.count) urgent, \(actionNeeded.count) action needed)",
                            actions: actions, outputPath: digestPath)
        } catch {
            return JobResult(name: "Email Digest", status: .failed,
                            summary: "Failed: \(error.localizedDescription)", actions: actions, outputPath: nil)
        }
    }

    // MARK: - Job 2: File Organization

    static func runFileOrganization() async -> JobResult {
        print("[OvernightJobs] Running file organization...")
        var actions: [String] = []
        let config = WorkspaceConfig.shared
        let fm = FileManager.default

        // Ensure _Inbox exists
        try? fm.createDirectory(atPath: config.inboxPath, withIntermediateDirectories: true)

        // Scan Downloads for school documents
        guard let downloads = try? fm.contentsOfDirectory(atPath: config.downloadsPath) else {
            return JobResult(name: "File Organization", status: .completed,
                            summary: "Could not read Downloads", actions: [], outputPath: nil)
        }

        var movedCount = 0
        var inboxCount = 0
        var cleanedCount = 0

        for filename in downloads where !filename.hasPrefix(".") {
            let ext = (filename as NSString).pathExtension.lowercased()
            let sourcePath = config.downloadsPath + "/" + filename

            // Skip non-document files
            guard WorkspaceConfig.schoolDocExtensions.contains(ext) else { continue }

            // Skip files currently being written (modified in last 60s)
            if let attrs = try? fm.attributesOfItem(atPath: sourcePath),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) < 60 { continue }

            // Route the file
            let route = config.routeFile(filename: filename)

            if route.confidence > 0.3 {
                // Confident match — move to subject folder
                let destPath = route.path + "/" + filename
                // Don't overwrite existing files
                guard !fm.fileExists(atPath: destPath) else {
                    actions.append("Skipped \(filename) (already exists in \(route.subject))")
                    continue
                }
                do {
                    try fm.moveItem(atPath: sourcePath, toPath: destPath)
                    actions.append("\(filename) → \(route.subject)")
                    movedCount += 1
                } catch {
                    actions.append("Failed to move \(filename): \(error.localizedDescription)")
                }
            } else {
                // Low confidence — move to inbox
                let destPath = config.inboxPath + "/" + filename
                guard !fm.fileExists(atPath: destPath) else { continue }
                do {
                    try fm.moveItem(atPath: sourcePath, toPath: destPath)
                    actions.append("\(filename) → _Inbox (needs manual sort)")
                    inboxCount += 1
                } catch {}
            }
        }

        // Clean up junk files in workspace
        cleanedCount = cleanJunkFiles(in: config.workspaceRoot, fm: fm)
        if cleanedCount > 0 {
            actions.append("Cleaned \(cleanedCount) system junk files (.DS_Store, lock files)")
        }

        let summary = "Moved \(movedCount) files to subjects, \(inboxCount) to _Inbox, cleaned \(cleanedCount) junk files"
        return JobResult(name: "File Organization", status: .completed,
                        summary: summary, actions: actions, outputPath: nil)
    }

    /// Recursively clean junk files from a directory.
    private static func cleanJunkFiles(in directory: String, fm: FileManager) -> Int {
        var cleaned = 0
        guard let enumerator = fm.enumerator(atPath: directory) else { return 0 }

        while let file = enumerator.nextObject() as? String {
            let filename = (file as NSString).lastPathComponent
            if WorkspaceConfig.isJunkFile(filename) {
                let fullPath = directory + "/" + file
                // Only delete if older than 24 hours (avoid deleting active Word locks)
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(modDate) > 86400 {
                    try? fm.removeItem(atPath: fullPath)
                    cleaned += 1
                }
            }
        }
        return cleaned
    }

    // MARK: - Job 3: Calendar Prep

    static func runCalendarPrep() async -> JobResult {
        print("[OvernightJobs] Running calendar prep...")
        var actions: [String] = []

        do {
            let calResult = try await ToolRegistry.shared.execute(
                toolName: "query_calendar_events",
                arguments: "{\"hours_ahead\": 48}"
            )

            guard !calResult.contains("No events") && !calResult.isEmpty else {
                return JobResult(name: "Calendar Prep", status: .completed,
                                summary: "No upcoming events", actions: [], outputPath: nil)
            }

            let events = calResult.components(separatedBy: "\n").filter { !$0.isEmpty }
            let prepKeywords = ["deadline", "exam", "test", "presentation", "submit", "due", "meeting", "prepare"]

            var prepEvents: [String] = []
            for event in events {
                let lower = event.lowercased()
                if prepKeywords.contains(where: { lower.contains($0) }) {
                    prepEvents.append(event)
                }
            }

            guard !prepEvents.isEmpty else {
                return JobResult(name: "Calendar Prep", status: .completed,
                                summary: "No events requiring preparation", actions: [], outputPath: nil)
            }

            // Build prep document
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            var prepLines = ["# Calendar Prep — \(formatter.string(from: Date()))"]
            prepLines.append("")
            prepLines.append("**\(prepEvents.count) events need preparation:**")
            prepLines.append("")

            for event in prepEvents {
                prepLines.append("## \(event)")

                // Search for related files in G8
                let keywords = event.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 3 }
                    .prefix(3)

                if !keywords.isEmpty {
                    let query = keywords.joined(separator: " ")
                    if let searchResult = try? await ToolRegistry.shared.execute(
                        toolName: "find_files",
                        arguments: "{\"query\": \"\(query)\", \"limit\": 5}"
                    ), !searchResult.isEmpty {
                        prepLines.append("**Related files found:**")
                        for line in searchResult.components(separatedBy: "\n").prefix(5) where !line.isEmpty {
                            prepLines.append("  - \(line)")
                        }
                    }
                }

                prepLines.append("**TODO:** Review materials and prepare for this event")
                prepLines.append("")
                actions.append("Prepared for: \(event.prefix(60))")
            }

            // Write prep file
            let workspace = WorkspaceConfig.shared.workspaceRoot
            let prepPath = workspace + "/Calendar Prep \(formatter.string(from: Date())).md"
            try prepLines.joined(separator: "\n").write(
                toFile: prepPath, atomically: true, encoding: .utf8
            )

            return JobResult(name: "Calendar Prep", status: .completed,
                            summary: "Prepared for \(prepEvents.count) upcoming events",
                            actions: actions, outputPath: prepPath)
        } catch {
            return JobResult(name: "Calendar Prep", status: .failed,
                            summary: "Failed: \(error.localizedDescription)", actions: actions, outputPath: nil)
        }
    }

    // MARK: - Job 4: Research Tasks

    static func runResearchTasks() async -> JobResult {
        print("[OvernightJobs] Running research tasks...")
        var actions: [String] = []

        // Check GoalStack for research-related goals
        let goals = await GoalStack.shared.activeGoals()
        let researchGoals = goals.filter { goal in
            let lower = goal.title.lowercased() + " " + goal.description.lowercased()
            return lower.contains("research") || lower.contains("find") || lower.contains("look up") || lower.contains("investigate")
        }

        guard !researchGoals.isEmpty else {
            return JobResult(name: "Research Tasks", status: .completed,
                            summary: "No research goals in GoalStack", actions: [], outputPath: nil)
        }

        var researchCount = 0
        for goal in researchGoals.prefix(3) {
            // Use headless browser to research
            do {
                let searchQuery = goal.title
                let result = try await ToolRegistry.shared.execute(
                    toolName: "browser_extract",
                    arguments: "{\"url\": \"https://www.google.com/search?q=\(searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery)\", \"instruction\": \"Extract the top 5 search results with titles and snippets\"}"
                )

                if !result.isEmpty {
                    // Save research notes
                    let workspace = WorkspaceConfig.shared.workspaceRoot
                    let safeName = goal.title.replacingOccurrences(of: "/", with: "-").prefix(50)
                    let notePath = workspace + "/Research - \(safeName).md"

                    var noteLines = ["# Research: \(goal.title)"]
                    noteLines.append("*Generated overnight on \(Date())*")
                    noteLines.append("")
                    noteLines.append(result)

                    try noteLines.joined(separator: "\n").write(
                        toFile: notePath, atomically: true, encoding: .utf8
                    )
                    actions.append("Researched: \(goal.title)")
                    researchCount += 1
                }
            } catch {
                actions.append("Research failed for: \(goal.title) — \(error.localizedDescription)")
            }
        }

        return JobResult(name: "Research Tasks", status: researchCount > 0 ? .completed : .skipped,
                        summary: "Researched \(researchCount) of \(researchGoals.count) goals",
                        actions: actions, outputPath: nil)
    }
}

// MARK: - Job Result Models

struct JobResult: Codable {
    let name: String
    let status: JobStatus
    let summary: String
    let actions: [String]
    let outputPath: String?

    enum JobStatus: String, Codable {
        case completed, failed, skipped
    }
}

struct JobRunResult: Codable {
    let jobs: [JobResult]
    let totalDuration: TimeInterval
    let startTime: Date

    var completedJobs: Int { jobs.filter { $0.status == .completed }.count }
    var failedJobs: Int { jobs.filter { $0.status == .failed }.count }

    func toMarkdown() -> String {
        var lines = ["# Overnight Job Report"]
        lines.append("*Run at \(startTime), duration: \(Int(totalDuration))s*")
        lines.append("")
        for job in jobs {
            let icon = job.status == .completed ? "done" : job.status == .failed ? "FAILED" : "skipped"
            lines.append("## \(job.name) [\(icon)]")
            lines.append(job.summary)
            if !job.actions.isEmpty {
                for action in job.actions {
                    lines.append("  - \(action)")
                }
            }
            if let path = job.outputPath {
                lines.append("  Output: `\(path)`")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
