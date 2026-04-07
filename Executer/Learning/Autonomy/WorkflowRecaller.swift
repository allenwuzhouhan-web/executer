import Foundation

/// Natural language workflow recall engine.
///
/// Phase 6 of the Workflow Recorder ("The Whisperer").
/// "Do that thing I did with the invoices last Tuesday" →
/// finds the exact workflow using temporal parsing + semantic search + context matching.
enum WorkflowRecaller {

    // MARK: - Recall

    /// Recall workflows matching a natural language query.
    /// Returns ranked matches with explanations.
    static func recall(query: String, limit: Int = 5) async -> [RecallResult] {
        // Step 1: Parse temporal constraints
        let temporal = TemporalParser.parse(query)

        // Step 2: Strip temporal words from query for semantic search
        let cleanedQuery = temporal.strippedQuery.isEmpty ? query : temporal.strippedQuery

        // Step 3: Search the repository
        let searchResults = await WorkflowRepository.shared.search(query: cleanedQuery, limit: limit * 2)

        // Step 4: Apply temporal filtering if present
        var results: [RecallResult] = []
        for sr in searchResults {
            var timeScore = 1.0

            if let after = temporal.after {
                if sr.workflow.createdAt < after { continue }  // Too old
            }
            if let before = temporal.before {
                if sr.workflow.createdAt > before { continue }  // Too new
            }
            if temporal.after != nil || temporal.before != nil {
                timeScore = 1.2  // Bonus for matching temporal constraint
            }

            let finalScore = sr.score * timeScore
            results.append(RecallResult(
                workflow: sr.workflow,
                score: min(finalScore, 1.0),
                matchReason: buildMatchReason(sr: sr, temporal: temporal),
                matchedTerms: sr.matchedTerms
            ))
        }

        // Sort by score and return top N
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    /// Quick check: does this query look like a recall request?
    /// Used by LocalCommandRouter for zero-LLM routing.
    static func isRecallIntent(_ query: String) -> Bool {
        let lower = query.lowercased()
        let recallPatterns = [
            "do that again", "do it again", "repeat that", "do that thing",
            "do what i did", "the thing i did", "that workflow",
            "remember when i", "that thing with", "last time i",
            "do the same", "same thing", "replay", "redo that",
        ]
        return recallPatterns.contains(where: { lower.contains($0) })
    }

    /// Build a human-readable match reason.
    private static func buildMatchReason(sr: WorkflowRepository.SearchResult, temporal: TemporalParser.ParseResult) -> String {
        var parts: [String] = []

        if !sr.matchedTerms.isEmpty {
            parts.append("matched: \(sr.matchedTerms.joined(separator: ", "))")
        }

        if temporal.after != nil || temporal.before != nil {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            if let after = temporal.after {
                parts.append("after \(formatter.string(from: after))")
            }
        }

        let app = sr.workflow.applicability.primaryApp
        parts.append("in \(app)")

        return parts.joined(separator: " — ")
    }

    // MARK: - Disambiguation

    /// When multiple workflows match, produce a disambiguation prompt.
    static func disambiguate(_ results: [RecallResult]) -> String {
        guard results.count > 1 else {
            if let r = results.first {
                return "Found: \(r.workflow.name) (\(r.workflow.description))"
            }
            return "No matching workflows found."
        }

        var lines = ["I found \(results.count) matching workflows:"]
        for (i, r) in results.prefix(5).enumerated() {
            let created = formatRelativeDate(r.workflow.createdAt)
            lines.append("  \(i + 1). \(r.workflow.name) — \(created) (\(r.matchReason))")
        }
        lines.append("Which one did you mean?")
        return lines.joined(separator: "\n")
    }

    private static func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Types

    struct RecallResult: Sendable {
        let workflow: GeneralizedWorkflow
        let score: Double
        let matchReason: String
        let matchedTerms: [String]
    }
}

// MARK: - Temporal Parser

/// Extracts time references from natural language queries.
/// "last Tuesday" → after: Tuesday 00:00, before: Wednesday 00:00
/// "yesterday" → after: yesterday 00:00, before: today 00:00
/// "last week" → after: 7 days ago, before: now
enum TemporalParser {

    struct ParseResult {
        let after: Date?           // Results must be after this date
        let before: Date?          // Results must be before this date
        let strippedQuery: String  // Query with temporal words removed
    }

    static func parse(_ query: String) -> ParseResult {
        let lower = query.lowercased()
        let calendar = Calendar.current
        let now = Date()
        var after: Date?
        var before: Date?
        var strippedWords: [String] = []

        // "today"
        if lower.contains("today") {
            after = calendar.startOfDay(for: now)
            before = now
            strippedWords.append("today")
        }

        // "yesterday"
        if lower.contains("yesterday") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            after = calendar.startOfDay(for: yesterday)
            before = calendar.startOfDay(for: now)
            strippedWords.append("yesterday")
        }

        // "last week"
        if lower.contains("last week") {
            after = calendar.date(byAdding: .day, value: -7, to: now)
            before = now
            strippedWords.append(contentsOf: ["last", "week"])
        }

        // "last month"
        if lower.contains("last month") {
            after = calendar.date(byAdding: .month, value: -1, to: now)
            before = now
            strippedWords.append(contentsOf: ["last", "month"])
        }

        // Day names: "last Monday", "last Tuesday", etc.
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for (i, dayName) in dayNames.enumerated() {
            if lower.contains(dayName) {
                // Find the most recent occurrence of this day
                let targetWeekday = i + 2  // Calendar weekday: Sunday=1, Monday=2, ...
                if targetWeekday > 7 { continue }
                var components = DateComponents()
                components.weekday = targetWeekday
                if let targetDate = calendar.nextDate(after: now, matching: components, matchingPolicy: .previousTimePreservingSmallerComponents, direction: .backward) {
                    after = calendar.startOfDay(for: targetDate)
                    before = calendar.date(byAdding: .day, value: 1, to: after!)
                }
                strippedWords.append(dayName)
                strippedWords.append("last")
                break
            }
        }

        // "this morning", "this afternoon"
        if lower.contains("this morning") {
            after = calendar.startOfDay(for: now)
            before = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)
            strippedWords.append(contentsOf: ["this", "morning"])
        }
        if lower.contains("this afternoon") {
            after = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)
            before = now
            strippedWords.append(contentsOf: ["this", "afternoon"])
        }

        // Strip temporal words from query
        var stripped = lower
        for word in strippedWords {
            stripped = stripped.replacingOccurrences(of: word, with: "")
        }
        // Clean up extra spaces and common filler
        stripped = stripped.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading "the", "that", "do", "i did"
        for prefix in ["do ", "the ", "that ", "i did ", "thing i did ", "thing with "] {
            if stripped.hasPrefix(prefix) {
                stripped = String(stripped.dropFirst(prefix.count))
            }
        }

        return ParseResult(after: after, before: before, strippedQuery: stripped)
    }
}
