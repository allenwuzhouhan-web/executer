import Foundation
import AppKit

/// Builds formatted context strings from the Learning system
/// for injection into LLM system prompts.
///
/// Three-layer injection strategy (hard budget ~3000 chars):
/// 1. Auto-inject: Today's sessions + current session (always, ~800 chars)
/// 2. Query-match: Last 7 days relevance-matched sessions (~1200 chars)
/// 3. On-demand: Historical retrieval via recall_work_context tool (~1000 chars)
enum LearningContextProvider {

    /// Returns the complete learning context for prompt injection.
    /// Combines patterns + session awareness + attention data.
    static func fullContextSection(forApp appName: String, query: String = "") -> String {
        var sections: [String] = []

        // Layer 1: Pattern context (from Phase 1)
        let patterns = promptSection(forApp: appName)
        if !patterns.isEmpty {
            sections.append(patterns)
        }

        // Layer 1b: Current session awareness
        let sessionContext = currentSessionContext()
        if !sessionContext.isEmpty {
            sections.append(sessionContext)
        }

        // Layer 1c: Motivation context (goals + deadlines)
        let motivationContext = PriorityRanker.topGoalsForPrompt()
        if !motivationContext.isEmpty {
            sections.append(motivationContext)
        }

        // Layer 1d: Current intent
        if let session = SessionDetector.shared.currentSession() {
            let motivation = PriorityRanker.motivationContext(for: session)
            if !motivation.isEmpty {
                sections.append("## Current Intent: \(motivation)")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    /// Returns learned patterns formatted for LLM prompt injection.
    static func promptSection(forApp appName: String) -> String {
        let patterns = LearningDatabase.shared.topPatterns(
            forApp: appName,
            limit: LearningConstants.maxPatternsInPrompt
        )
        guard !patterns.isEmpty else { return "" }

        var lines = ["## Learned Patterns for \(appName) (from observing the user):"]
        for pattern in patterns {
            lines.append("### \(pattern.name) (observed \(pattern.frequency)x)")
            for (i, action) in pattern.actions.enumerated() {
                var step = "  \(i + 1). \(action.type.rawValue)"
                if !action.elementTitle.isEmpty { step += " → \"\(action.elementTitle)\"" }
                if !action.elementRole.isEmpty { step += " [\(action.elementRole)]" }
                if !action.elementValue.isEmpty { step += " = \"\(String(action.elementValue.prefix(80)))\"" }
                lines.append(step)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns patterns for the frontmost app.
    static func promptSectionForFrontmostApp() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return "" }
        return promptSection(forApp: name)
    }

    // MARK: - Session Context

    /// Returns current session info for prompt injection.
    private static func currentSessionContext() -> String {
        guard let session = SessionDetector.shared.currentSession() else { return "" }

        var lines = ["## Current Work Session:"]
        lines.append("**\(session.title)** (\(session.durationFormatted))")
        lines.append("Apps: \(session.apps.joined(separator: " → "))")
        if !session.topics.isEmpty {
            lines.append("Topics: \(session.topics.sorted().prefix(5).joined(separator: ", "))")
        }

        // Add today's other sessions as brief context
        let todaysSessions = SessionDetector.shared.todaysSessions()
        if todaysSessions.count > 1 {
            lines.append("\nToday's other sessions:")
            for s in todaysSessions where s.id != session.id {
                lines.append("- \(s.title) (\(s.durationFormatted))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
