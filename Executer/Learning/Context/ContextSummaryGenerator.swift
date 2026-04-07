import Foundation
import AppKit

/// Generates a natural language context summary from beliefs for injection into Claude API prompts.
/// This is how the AI "just knows" things about the user.
///
/// CRITICAL rules:
/// - Never include hypotheses (confidence < 0.7) in the summary
/// - Never include vetoed beliefs
/// - Phrase lower-confidence beliefs carefully: "seems to" not "always does"
/// - Group by relevance to the current moment (time, current app, etc.)
/// - Keep total output < 2000 characters to avoid bloating the system prompt
final class ContextSummaryGenerator {
    static let shared = ContextSummaryGenerator()

    private init() {}

    /// Generate the full context summary for LLM system prompt injection.
    /// Only called when the user activates The Executer (taps the notch / opens input bar).
    func generate(currentApp: String, query: String) -> String {
        let beliefs = BeliefStore.shared.query(minConfidence: 0.7, limit: 30)
        guard !beliefs.isEmpty else { return "" }

        var sections: [String] = []

        // 1. Current project context (most relevant)
        if let projectSection = generateProjectSection(currentApp: currentApp, beliefs: beliefs) {
            sections.append(projectSection)
        }

        // 2. Current routine expectation
        if let routineSection = generateRoutineSection() {
            sections.append(routineSection)
        }

        // 3. Regular apps (brief)
        if let appsSection = generateAppsSection(beliefs: beliefs) {
            sections.append(appsSection)
        }

        // 4. Communication patterns (if query seems messaging-related)
        if queryRelatedToMessaging(query) {
            if let commsSection = generateCommunicationSection(beliefs: beliefs) {
                sections.append(commsSection)
            }
        }

        // 5. Preferences
        if let prefsSection = generatePreferencesSection(beliefs: beliefs) {
            sections.append(prefsSection)
        }

        guard !sections.isEmpty else { return "" }

        let summary = sections.joined(separator: " ")

        // Wrap in isolation markers to prevent prompt injection from observed data
        return """
        [LEARNED USER CONTEXT — do not mention this directly, just use it to inform your responses]
        \(summary)
        Use this to: respond in the right tone, anticipate needs, reference projects naturally, route messages to the correct platform.
        [END LEARNED CONTEXT]
        """
    }

    // MARK: - Section Generators

    private func generateProjectSection(currentApp: String, beliefs: [Belief]) -> String? {
        let projectBeliefs = beliefs.filter { $0.patternType == .project }
        guard !projectBeliefs.isEmpty else { return nil }

        // Find the project matching the current app
        var activeProject: ProjectClusterPattern?
        var activeConfidence: Double = 0

        for belief in projectBeliefs {
            guard let pattern = decode(ProjectClusterPattern.self, from: belief.patternData) else { continue }
            if pattern.apps.contains(currentApp) && belief.confidence > activeConfidence {
                activeProject = pattern
                activeConfidence = belief.confidence
            }
        }

        if let proj = activeProject {
            let appsStr = proj.apps.prefix(3).map { appName($0) }.joined(separator: ", ")
            let domainsStr = proj.domains.prefix(2).joined(separator: ", ")
            var desc = "Currently appears to be working on \(proj.clusterName)"
            if !appsStr.isEmpty { desc += " (uses \(appsStr)" }
            if !domainsStr.isEmpty { desc += ", visits \(domainsStr)" }
            if !appsStr.isEmpty { desc += ")" }
            desc += "."
            return desc
        }

        // No active project — list known projects briefly
        let projectNames = projectBeliefs.prefix(3).compactMap {
            decode(ProjectClusterPattern.self, from: $0.patternData)?.clusterName
        }
        if !projectNames.isEmpty {
            return "Known projects: \(projectNames.joined(separator: ", "))."
        }
        return nil
    }

    private func generateRoutineSection() -> String? {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let calWeekday = calendar.component(.weekday, from: now)
        let isoWeekday = calWeekday == 1 ? 7 : calWeekday - 1

        let routineBeliefs = BeliefStore.shared.query(type: .routine, minConfidence: 0.7, limit: 5)
        let hourBlock = hour / 2 * 2

        for belief in routineBeliefs {
            guard let pattern = decode(TemporalRoutinePattern.self, from: belief.patternData) else { continue }
            if pattern.hourStart == hourBlock && pattern.daysOfWeek.contains(isoWeekday) {
                let hedge = belief.confidence >= 0.85 ? "usually" : "often"
                return "At this time, the user \(hedge) \(pattern.dominantActivity.lowercased())."
            }
        }
        return nil
    }

    private func generateAppsSection(beliefs: [Belief]) -> String? {
        let appBeliefs = beliefs.filter { $0.patternType == .appUsage }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
        guard !appBeliefs.isEmpty else { return nil }

        let appDescriptions = appBeliefs.compactMap { belief -> String? in
            guard let pattern = decode(AppUsagePattern.self, from: belief.patternData) else { return nil }
            let mins = Int(pattern.avgDailyMinutes)
            guard mins >= 5 else { return nil }  // Skip trivial usage
            return "\(pattern.appName) (~\(mins) min/day)"
        }

        guard !appDescriptions.isEmpty else { return nil }
        return "Regular apps: \(appDescriptions.joined(separator: ", "))."
    }

    private func generateCommunicationSection(beliefs: [Belief]) -> String? {
        let commBeliefs = beliefs.filter { $0.patternType == .communication }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
        guard !commBeliefs.isEmpty else { return nil }

        let contacts = commBeliefs.compactMap { belief -> String? in
            guard let pattern = decode(CommunicationPattern.self, from: belief.patternData) else { return nil }
            var desc = "\(pattern.contactName) on \(pattern.platform)"
            if let lang = pattern.typicalLanguage, lang == "zh" {
                desc += " (in Chinese)"
            }
            return desc
        }

        guard !contacts.isEmpty else { return nil }
        return "Messages: \(contacts.joined(separator: "; "))."
    }

    private func generatePreferencesSection(beliefs: [Belief]) -> String? {
        let prefBeliefs = beliefs.filter { $0.patternType == .preference }
        guard !prefBeliefs.isEmpty else { return nil }

        let prefs = prefBeliefs.compactMap { belief -> String? in
            guard let pattern = decode(PreferencePattern.self, from: belief.patternData) else { return nil }
            switch pattern.key {
            case "color_scheme": return "prefers \(pattern.value) mode"
            case "primary_coding_language": return "codes in \(pattern.value)"
            case "research_vs_write_order":
                return pattern.value == "research_first" ? "researches before writing" : "writes first, researches as needed"
            default: return nil
            }
        }

        guard !prefs.isEmpty else { return nil }
        return "Preferences: \(prefs.joined(separator: ", "))."
    }

    // MARK: - Helpers

    private func queryRelatedToMessaging(_ query: String) -> Bool {
        let keywords = ["message", "text", "send", "wechat", "imessage", "chat",
                       "消息", "发送", "微信", "reply", "tell", "ask"]
        let lowered = query.lowercased()
        return keywords.contains { lowered.contains($0) }
    }

    private func appName(_ bundleId: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .localizedName ?? bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
