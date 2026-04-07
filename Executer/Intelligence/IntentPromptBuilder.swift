import Foundation

/// Builds the LLM prompt for the Intent Engine with project state, radar signals, time context, and goals.
enum IntentPromptBuilder {

    static func buildDiscoveryPrompt(
        projects: [ProjectNode],
        signals: [RadarSignal],
        goals: [ManagedGoal],
        currentTime: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, h:mm a"
        let timeStr = formatter.string(from: currentTime)

        let hour = Calendar.current.component(.hour, from: currentTime)
        let timeContext: String
        if hour < 6 { timeContext = "late night — user is sleeping, focus on background tasks" }
        else if hour < 9 { timeContext = "early morning — prepare briefing, organize files" }
        else if hour < 12 { timeContext = "morning — user may be starting work soon" }
        else if hour < 17 { timeContext = "afternoon — user is likely working" }
        else if hour < 22 { timeContext = "evening — wind-down, prep for tomorrow" }
        else { timeContext = "night — user going to sleep soon, start overnight work" }

        var prompt = """
        You are a task discovery engine. Analyze the user's projects, recent signals, and goals to determine what tasks should be worked on autonomously.

        Current time: \(timeStr) (\(timeContext))

        ## Active Projects
        """

        for p in projects.prefix(10) {
            let pct = Int(p.completionEstimate * 100)
            prompt += "\n- \(p.name) (\(pct)% complete, \(p.files.count) files)"
            if !p.tags.isEmpty { prompt += " [\(p.tags.joined(separator: ","))]" }
            let deadlines = p.deadlines.filter { !$0.completed }
            if let next = deadlines.sorted(by: { $0.date < $1.date }).first {
                let df = DateFormatter()
                df.dateStyle = .short
                prompt += " — deadline: \(next.title) on \(df.string(from: next.date))"
            }
        }

        if !signals.isEmpty {
            prompt += "\n\n## Recent Signals (last few hours)\n"
            for s in signals.suffix(20) {
                prompt += "- [\(s.source.rawValue)] \(s.title) (urgency: \(String(format: "%.1f", s.urgency)))\n"
            }
        }

        if !goals.isEmpty {
            prompt += "\n\n## Active Goals\n"
            for g in goals.prefix(5) {
                let pending = g.subGoals.filter { $0.state == .pending }.count
                prompt += "- \(g.title) (priority: \(String(format: "%.1f", g.priority)), \(pending) pending steps)\n"
            }
        }

        prompt += """

        ## Instructions
        Based on this context, output a JSON array of tasks to execute. Each task:
        - Should be actionable using the user's existing tools (file operations, email, web search, document creation)
        - Should have clear success criteria
        - Should not duplicate existing goals

        Output format:
        ```json
        [
          {
            "title": "short task title",
            "description": "what to do and why",
            "source": "email|calendar|reminder|goalStack|fileChange|manual",
            "priority": 0.0-1.0,
            "estimated_minutes": 5-30
          }
        ]
        ```

        Output ONLY the JSON array. Max 10 tasks, sorted by priority.
        """

        return prompt
    }
}
