import Foundation
import AppKit

/// Tool that reads the full UI tree of the frontmost app via Accessibility APIs.
/// No screen recording needed — uses AXUIElement to traverse elements.
struct ReadScreenTool: ToolDefinition {
    let name = "read_screen"
    let description = "Read the entire UI of the frontmost application — all text, buttons, menus, fields, and their positions. Uses Accessibility APIs, no screen recording needed. Returns a structured tree of UI elements."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "max_elements": JSONSchema.integer(description: "Maximum elements to return (default 80, max 200)", minimum: 10, maximum: 200),
        ])
    }

    func execute(arguments: String) async throws -> String {
        guard let snapshot = ScreenReader.readFrontmostApp() else {
            return "Could not read the frontmost app. Make sure Accessibility permission is granted."
        }
        return snapshot.summary()
    }
}

/// Tool that reads the visible text from the frontmost app (lightweight).
struct ReadAppTextTool: ToolDefinition {
    let name = "read_app_text"
    let description = "Read all visible text from the frontmost application. Faster than read_screen — returns just the text content without positions or element types."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application."
        }
        let texts = ScreenReader.readVisibleText(pid: app.processIdentifier)
        if texts.isEmpty {
            return "No readable text found in \(app.localizedName ?? "the app")."
        }
        return "Text from \(app.localizedName ?? "app"):\n\(texts.joined(separator: "\n"))"
    }
}

/// Tool that returns the user's learned workflow patterns for an app.
struct GetLearnedPatternsTool: ToolDefinition {
    let name = "get_learned_patterns"
    let description = "Get the user's learned workflow patterns for a specific app. Shows how the user typically uses the app — what they click, what they type, in what order. Use this to replicate the user's workflow."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The app name (e.g. 'Keynote', 'Safari', 'Microsoft PowerPoint')"),
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        let patterns = LearningContextProvider.promptSection(forApp: appName)
        if patterns.isEmpty {
            return "No learned patterns for \(appName) yet. The user hasn't used this app enough while Executer was running."
        }
        return patterns
    }
}

/// Tool that lists all apps with learned patterns.
struct ListLearnedAppsTool: ToolDefinition {
    let name = "list_learned_apps"
    let description = "List all apps that Executer has learned patterns from, with pattern and action counts."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        return LearningManager.shared.overallSummary()
    }
}

// MARK: - Phase 2 Tools

/// Tool that returns the current active work session.
struct GetCurrentSessionTool: ToolDefinition {
    let name = "get_current_session"
    let description = "Get what the user is currently working on — reads the screen, detects apps, and reports the active session. Use this to understand the user's current context."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        var parts: [String] = []

        // 1. What app is the user actually in? (captured before input bar opened)
        let delegate = NSApplication.shared.delegate as? AppDelegate
        let userApp = await delegate?.appState.lastFrontmostAppName ?? "Unknown"
        parts.append("**Frontmost app:** \(userApp)")

        // 2. Read visible text from that app (actual screen content)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == userApp }) {
            let texts = ScreenReader.readVisibleText(pid: app.processIdentifier)
            if !texts.isEmpty {
                let preview = texts.prefix(20).joined(separator: " | ")
                parts.append("**Visible on screen:** \(String(preview.prefix(500)))")
            }
        }

        // 3. What other apps are running?
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .map { $0.localizedName! }
        parts.append("**Running apps:** \(running.joined(separator: ", "))")

        // 4. Active workflow journal (from Workflow Recorder — live task tracking)
        let activeJournal = await JournalManager.shared.activeJournal
        if let journal = activeJournal {
            parts.append("\n**Current task:** \(journal.taskDescription.isEmpty ? "Active task" : journal.taskDescription) (\(journal.durationFormatted))")
            parts.append("**Task apps:** \(journal.apps.joined(separator: " → "))")
            if !journal.topicTerms.isEmpty {
                parts.append("**Topics:** \(journal.topicTerms.prefix(8).joined(separator: ", "))")
            }
            // Show last few actions for context
            let recentEntries = journal.entries.suffix(5)
            if !recentEntries.isEmpty {
                parts.append("**Recent actions:**")
                for entry in recentEntries {
                    parts.append("  - \(entry.semanticAction) [\(entry.appContext)]")
                }
            }
        }

        // 5. Recent closed journals (what user did before current task)
        let recentJournals = JournalStore.shared.recentJournals(limit: 3, status: .closed)
        if !recentJournals.isEmpty {
            parts.append("\n**Previous tasks:**")
            for j in recentJournals {
                parts.append("  - \(j.taskDescription.isEmpty ? "Untitled" : j.taskDescription) (\(j.durationFormatted), \(j.apps.joined(separator: "→")))")
            }
        }

        // 6. Explicit instruction to prevent hallucination
        parts.append("\nIMPORTANT: Only report what is shown above. Do NOT invent app usage times, hours invested, or project details that aren't in this data.")

        return parts.joined(separator: "\n")
    }
}

/// Tool that returns today's work context.
struct GetTodayContextTool: ToolDefinition {
    let name = "get_today_context"
    let description = "Get what the user has been working on today — all work sessions, topics, apps used, and key observations."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        // Use Workflow Recorder journals for accurate today context
        let allJournals = JournalStore.shared.recentJournals(limit: 50)
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayJournals = allJournals.filter { $0.startTime >= todayStart }

        // Also include the active journal
        let activeJournal = await JournalManager.shared.activeJournal

        let totalJournals = todayJournals.count + (activeJournal != nil ? 1 : 0)
        guard totalJournals > 0 else {
            return "No work sessions recorded today yet. The workflow recorder is active and will capture your tasks as you work."
        }

        var lines = ["## Today's Tasks (\(totalJournals)):"]

        // Show active journal first
        if let active = activeJournal {
            lines.append("\n**[ACTIVE]** \(active.taskDescription.isEmpty ? "Current task" : active.taskDescription) (\(active.durationFormatted))")
            lines.append("   Apps: \(active.apps.joined(separator: " → "))")
            if !active.topicTerms.isEmpty {
                lines.append("   Topics: \(active.topicTerms.prefix(5).joined(separator: ", "))")
            }
        }

        // Show completed today journals
        for (i, journal) in todayJournals.prefix(10).enumerated() {
            let desc = journal.taskDescription.isEmpty ? "Task \(i + 1)" : journal.taskDescription
            lines.append("\n\(i + 1). **\(desc)** (\(journal.durationFormatted))")
            lines.append("   Apps: \(journal.apps.joined(separator: " → "))")
            if !journal.topicTerms.isEmpty {
                lines.append("   Topics: \(journal.topicTerms.prefix(5).joined(separator: ", "))")
            }
        }

        // Aggregate stats
        let allApps = Set((todayJournals.flatMap(\.apps)) + (activeJournal?.apps ?? []))
        let allTopics = Set((todayJournals.flatMap(\.topicTerms)) + (activeJournal?.topicTerms ?? []))
        lines.append("\n## Summary")
        lines.append("Apps used today: \(allApps.sorted().joined(separator: ", "))")
        if !allTopics.isEmpty {
            lines.append("Topics: \(allTopics.sorted().prefix(10).joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}

/// Tool that searches historical work context (daily summaries).
struct RecallWorkContextTool: ToolDefinition {
    let name = "recall_work_context"
    let description = "Search the user's work history. Returns past work sessions matching the query — what apps they used, what topics they worked on, design choices made. Use when the user references past work or you need historical context."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "What to search for (e.g., 'Q1 report', 'pitch deck', 'Swift project')"),
            "days_back": JSONSchema.integer(description: "How many days back to search (default 30, max 365)", minimum: 1, maximum: 365),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)

        let results = ContextSearchIndex.shared.search(query: query, limit: 10)
        guard !results.isEmpty else {
            return "No matching work context found for '\(query)'. The user may not have worked on this topic recently."
        }

        var lines = ["## Work History for '\(query)':"]
        for result in results {
            lines.append("- **\(result.date)**: \(result.title)")
        }

        return lines.joined(separator: "\n")
    }
}

/// Tool that returns the daily summary for a specific date.
struct GetDailySummaryTool: ToolDefinition {
    let name = "get_daily_summary"
    let description = "Get the daily work summary for a specific date. Shows all sessions, apps used, topics, and key observations."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "date": JSONSchema.string(description: "The date to look up (YYYY-MM-DD format, e.g., '2026-03-28')"),
        ], required: ["date"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let date = try requiredString("date", from: args)

        let fm = FileManager.default
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer/daily_summaries", isDirectory: true)
        let file = dir.appendingPathComponent("\(date).md")

        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return "No summary found for \(date). Either the user wasn't active or the summary hasn't been generated yet."
        }

        return content
    }
}

// MARK: - Phase 3 Tools

/// Tool that returns the user's active goals.
struct GetUserGoalsTool: ToolDefinition {
    let name = "get_user_goals"
    let description = "Get the user's current work goals — multi-day objectives with accumulated time, deadlines, and priority. Use this to understand what the user is working toward."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let goals = GoalTracker.shared.topGoals(limit: 10)
        guard !goals.isEmpty else {
            return "No goals tracked yet. Goals are detected automatically from recurring work sessions."
        }

        var lines = ["## User's Active Goals:"]
        for goal in goals {
            lines.append(goal.summary())
        }

        let alerts = DeadlineAwareness.generateAlerts()
        if !alerts.isEmpty {
            lines.append("\n## Deadline Alerts:")
            for alert in alerts { lines.append("- \(alert)") }
        }

        return lines.joined(separator: "\n")
    }
}

/// Tool that returns the current work intent.
struct GetCurrentIntentTool: ToolDefinition {
    let name = "get_current_intent"
    let description = "Get why the user is doing what they're doing right now — inferred from calendar events, goals, and work patterns."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        guard let session = SessionDetector.shared.currentSession() else {
            return "No active work session. Cannot infer intent."
        }

        let goal = GoalTracker.shared.relevantGoal(for: session)
        let intent = IntentInferenceEngine.inferIntent(for: session, goal: goal)
        let motivation = IntentInferenceEngine.motivationSummary(session: session, goal: goal, intent: intent)

        var lines = ["## Current Work Intent:"]
        lines.append(motivation)
        lines.append("\n**Session:** \(session.title) (\(session.durationFormatted))")
        lines.append("**Apps:** \(session.apps.joined(separator: " → "))")
        if let goal = goal {
            lines.append("**Goal:** \(goal.topic) (\(goal.totalTimeFormatted) invested)")
        }

        return lines.joined(separator: "\n")
    }
}
