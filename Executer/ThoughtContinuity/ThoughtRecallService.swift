import Foundation
import Cocoa

struct ThoughtRecall: Equatable {
    let thoughtId: Int64
    let appBundleId: String
    let appName: String
    let windowTitle: String?
    let textPreview: String
    let summary: String
    let timeElapsed: TimeInterval
    let timestamp: Date
}

class ThoughtRecallService {
    static let shared = ThoughtRecallService()

    private let db = ThoughtDatabase.shared
    private var cachedRecall: ThoughtRecall?
    private var cacheTime: Date = .distantPast
    private let cacheDuration: TimeInterval = 60

    private init() {}

    // MARK: - Check for Abandoned Thoughts

    func checkForAbandonedThought() async -> ThoughtRecall? {
        // Return cache if fresh
        if let cached = cachedRecall, Date().timeIntervalSince(cacheTime) < cacheDuration {
            return cached
        }

        // Suppress in quiet focus modes
        if FocusStateService.shared.currentFocus == .sleep || FocusStateService.shared.currentFocus == .mindfulness {
            return nil
        }

        let abandoned = db.abandonedThoughts(abandonedAfter: 300) // 5 minutes
        guard let thought = abandoned.first else { return nil }

        // Skip if user has returned to this app since
        if db.hasNewerThought(bundleId: thought.appBundleId, since: thought.timestamp) {
            return nil
        }

        // Skip if this app is currently frontmost
        let isFrontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == thought.appBundleId
        }
        if isFrontmost { return nil }

        let textPreview = String(thought.textContent.prefix(500))
        let elapsed = Date().timeIntervalSince(thought.timestamp)

        // Generate summary via LLM
        let summary = await generateSummary(
            appName: thought.appName,
            windowTitle: thought.windowTitle,
            text: textPreview
        )

        let recall = ThoughtRecall(
            thoughtId: thought.id,
            appBundleId: thought.appBundleId,
            appName: thought.appName,
            windowTitle: thought.windowTitle,
            textPreview: textPreview,
            summary: summary,
            timeElapsed: elapsed,
            timestamp: thought.timestamp
        )

        cachedRecall = recall
        cacheTime = Date()
        return recall
    }

    // MARK: - Build Finish Task Prompt

    /// Builds a rich task description for the AgentLoop so it can use tools to finish the user's work.
    func buildFinishTaskPrompt(for recall: ThoughtRecall) -> String {
        let thought = db.mostRecentForApp(bundleId: recall.appBundleId)
        let text = thought.map { String($0.textContent.prefix(2000)) } ?? recall.textPreview
        let windowContext = recall.windowTitle.map { " (window: \($0))" } ?? ""

        return """
        [finish task] The user was working in \(recall.appName)\(windowContext) and left this unfinished. \
        Open \(recall.appName), navigate to where they left off, and complete the task using the appropriate tools. \
        Do NOT just generate text — actually interact with the app to finish the work.

        What they were doing: \(recall.summary)

        Their work so far:
        \(text)
        """
    }

    // MARK: - Mark Complete

    func markComplete(_ recall: ThoughtRecall) {
        db.markComplete(id: recall.thoughtId)
        if cachedRecall?.thoughtId == recall.thoughtId {
            cachedRecall = nil
        }
    }

    // MARK: - LLM Summary

    private func generateSummary(appName: String, windowTitle: String?, text: String) async -> String {
        var context = "App: \(appName)"
        if let title = windowTitle { context += ", Window: \(title)" }

        let prompt = """
        The user was typing in \(appName). Summarize what they were working on in ONE short sentence (max 15 words). \
        Be specific about the content, not generic.
        Context: \(context)
        Their text: \(text)
        """

        do {
            let messages = [
                ChatMessage(role: "user", content: prompt)
            ]
            let response = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: messages,
                tools: nil,
                maxTokens: 60
            )
            return response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackSummary(appName: appName, windowTitle: windowTitle)
        } catch {
            print("[ThoughtRecall] Summary generation failed: \(error)")
            return fallbackSummary(appName: appName, windowTitle: windowTitle)
        }
    }

    private func fallbackSummary(appName: String, windowTitle: String?) -> String {
        if let title = windowTitle, !title.isEmpty {
            return "You were working on \"\(title)\" in \(appName)"
        }
        return "You were typing in \(appName)"
    }

    // MARK: - Thought Summarization (Past Session Recall)

    /// Summarize recent thoughts matching a query. Returns a coherent summary instead of raw dumps.
    func summarizeRecentThoughts(query: String?) async -> String? {
        let thoughts: [ThoughtDatabase.ThoughtRecord]
        if let q = query, !q.isEmpty {
            thoughts = db.searchThoughts(query: q, limit: 10)
        } else {
            thoughts = db.recentThoughts(limit: 10)
        }

        guard !thoughts.isEmpty else { return nil }

        // Build context from thought records
        let entries = thoughts.map { t in
            let time = RelativeDateTimeFormatter().localizedString(for: t.timestamp, relativeTo: Date())
            return "[\(time)] \(t.appName): \(String(t.textContent.prefix(200)))"
        }
        let context = entries.joined(separator: "\n")

        let prompt = """
        Summarize these past interactions concisely in 2-3 sentences. \
        Focus on what was accomplished, decisions made, and key outcomes. \
        Be specific, not generic. Do not list — synthesize.

        \(context)
        """

        do {
            let messages = [ChatMessage(role: "user", content: prompt)]
            let response = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: messages, tools: nil, maxTokens: 150
            )
            return response.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[ThoughtRecall] Summarization failed: \(error)")
            return nil
        }
    }
}
