import Foundation

/// Periodically gathers cross-domain data (thoughts, memories, goals, files, activity)
/// and asks the LLM to find non-obvious connections the user hasn't noticed.
///
/// Integration points:
/// - CoworkerAgent: surfaces insights as `.synthesis` suggestions during the day
/// - OvernightAgent: includes insights in the morning report
actor SynthesisEngine {
    static let shared = SynthesisEngine()

    // MARK: - Configuration

    private let synthesisInterval: TimeInterval = 3600  // 60 min between runs (was 30min, doubled by foveal attention Stage 4)
    private let minSurpriseScore: Double = 0.6
    private let maxInsightsPerCycle: Int = 3
    private let maxSurfacedPerDay: Int = 8

    // MARK: - Cached Formatters (DateFormatter alloc is expensive)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let docExtensions: Set<String> = [
        "pdf", "pptx", "docx", "xlsx", "txt", "md", "csv", "pages", "key", "numbers"
    ]

    // MARK: - State

    private var lastSynthesisTime: Date = .distantPast
    private var surfacedToday: Int = 0
    private var surfacedTodayDate: String = ""
    private var daytimeTask: Task<Void, Never>?
    private var isRunning = false

    // Dedup: pre-computed word sets for O(1) lookup instead of recomputing every check
    private var recentHeadlineWords: [Set<String>] = []
    private var recentHeadlines: [String] = []
    private let maxRecentHeadlines = 20

    // In-memory insight cache — avoids disk reads on every 30s pipeline tick
    private var cachedInsights: [SynthesisInsight] = []
    private var cacheLoaded = false

    // Prune tracker — only prune old files once per day
    private var lastPruneDate: String = ""

    // MARK: - Persistence

    private static let storeDir: URL = {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer/synthesis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var todayFilename: String {
        dateFormatter.string(from: Date()) + ".json"
    }

    private static var todayFileURL: URL {
        storeDir.appendingPathComponent(todayFilename)
    }

    // MARK: - Lifecycle

    func startDaytime() {
        guard !isRunning else { return }
        isRunning = true
        loadCache()
        resetDailyCounterIfNeeded()

        print("[SynthesisEngine] Started (interval: \(Int(synthesisInterval))s)")

        daytimeTask = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(nanoseconds: UInt64(synthesisInterval) * 1_000_000_000)
                guard !Task.isCancelled && isRunning else { break }
                let _ = await synthesize()
            }
        }
    }

    func stop() {
        isRunning = false
        daytimeTask?.cancel()
        daytimeTask = nil
        print("[SynthesisEngine] Stopped")
    }

    // MARK: - Core API

    /// Previous context snapshot embedding for drift detection (Stage 4 gate).
    private var previousSnapshotEmbedding: [Double]?

    func synthesize() async -> [SynthesisInsight] {
        resetDailyCounterIfNeeded()

        let now = Date()
        guard now.timeIntervalSince(lastSynthesisTime) >= synthesisInterval else { return [] }
        lastSynthesisTime = now

        // Gather context from all sources in parallel
        let snapshot = await gatherContextSnapshot()

        // Skip if insufficient cross-domain data
        var sourceCount = 0
        if !snapshot.thoughtSummaries.isEmpty { sourceCount += 1 }
        if !snapshot.relevantMemories.isEmpty { sourceCount += 1 }
        if !snapshot.activeGoals.isEmpty { sourceCount += 1 }
        if !snapshot.recentFiles.isEmpty { sourceCount += 1 }
        if !snapshot.currentApp.isEmpty { sourceCount += 1 }

        guard sourceCount >= 3 else {
            return []
        }

        // Stage 4 drift gate: skip LLM call if context hasn't meaningfully changed
        let snapshotSummary = [
            snapshot.thoughtSummaries.joined(separator: " "),
            snapshot.activeGoals.joined(separator: " "),
            snapshot.currentApp,
            snapshot.recentFiles.joined(separator: " "),
        ].joined(separator: " ")

        if !FovealRouter.shouldCallAPI(
            currentSnapshot: snapshotSummary,
            previousEmbedding: &previousSnapshotEmbedding,
            driftThreshold: 0.7
        ) {
            print("[SynthesisEngine] Drift gate: context unchanged, skipping LLM call")
            return []
        }

        let prompt = buildPrompt(snapshot: snapshot)
        guard let responseText = await callLLM(prompt: prompt) else { return [] }

        var insights = parseInsights(from: responseText, snapshot: snapshot)
        insights = insights.filter { $0.surpriseScore >= minSurpriseScore }
        insights = deduplicateInsights(insights)
        insights = Array(insights.prefix(maxInsightsPerCycle))

        if !insights.isEmpty {
            appendInsights(insights)
            print("[SynthesisEngine] Found \(insights.count) insights")
        }

        return insights
    }

    /// Get the next pending insight for CoworkerAgent. O(1) from cache.
    func nextPendingInsight() -> SynthesisInsight? {
        resetDailyCounterIfNeeded()
        guard surfacedToday < maxSurfacedPerDay else { return nil }

        guard let best = cachedInsights
            .filter({ $0.surpriseScore >= minSurpriseScore })
            .sorted(by: { $0.surpriseScore > $1.surpriseScore })
            .first(where: { !isAlreadySurfaced($0.headline) })
        else { return nil }

        surfacedToday += 1
        addToRecentHeadlines(best.headline)
        return best
    }

    /// Broader overnight pass — bypasses rate limit for a single run.
    func runOvernightPass() async -> [SynthesisInsight] {
        let savedTime = lastSynthesisTime
        lastSynthesisTime = .distantPast
        let result = await synthesize()
        lastSynthesisTime = savedTime
        return result
    }

    // MARK: - Context Gathering (parallel)

    struct Snapshot {
        let thoughtSummaries: [String]
        let relevantMemories: [String]
        let activeGoals: [String]
        let recentFiles: [String]
        let currentApp: String
        let currentActivity: String
    }

    private func gatherContextSnapshot() async -> Snapshot {
        // Run independent data sources concurrently
        async let thoughtsTask = fetchThoughts()
        async let memoriesTask = fetchMemories()
        async let filesTask = scanRecentDownloads()
        async let workStateTask = WorkStateEngine.shared.snapshot()

        let thoughts = await thoughtsTask
        let memories = await memoriesTask
        let files = await filesTask
        let workState = await workStateTask

        // GoalStack.promptSection is synchronous (cached behind NSLock)
        let goalSection = GoalStack.promptSection
        let goals = goalSection.isEmpty ? [] : goalSection.components(separatedBy: "\n").filter { !$0.isEmpty }

        return Snapshot(
            thoughtSummaries: thoughts,
            relevantMemories: memories,
            activeGoals: goals,
            recentFiles: files,
            currentApp: workState.currentApp,
            currentActivity: "\(workState.activityType.rawValue) in \(workState.currentApp) — \(workState.windowTitle)"
        )
    }

    private nonisolated func fetchThoughts() -> [String] {
        ThoughtDatabase.shared.recentThoughts(limit: 20).map { t in
            let title = t.windowTitle ?? "untitled"
            let time = Self.timeFormatter.string(from: t.timestamp)
            return "[\(t.appName)] \(title) (\(time)): \(String(t.textContent.prefix(100)))"
        }
    }

    private nonisolated func fetchMemories() -> [String] {
        MemoryManager.shared.recall(limit: 30, namespace: "general").map { m in
            "[\(m.category.rawValue)] \(m.content)"
        }
    }

    private nonisolated func scanRecentDownloads() -> [String] {
        let downloadsPath = NSHomeDirectory() + "/Downloads"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: downloadsPath) else { return [] }

        let oneDayAgo = Date().addingTimeInterval(-86400)
        var files: [String] = []
        files.reserveCapacity(10)

        for filename in contents where !filename.hasPrefix(".") {
            let path = downloadsPath + "/" + filename
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > oneDayAgo else { continue }

            let ext = (filename as NSString).pathExtension.lowercased()
            if Self.docExtensions.contains(ext) {
                files.append(filename)
                if files.count >= 10 { break }
            }
        }
        return files
    }

    // MARK: - LLM Prompt

    private func buildPrompt(snapshot: Snapshot) -> String {
        // Pre-size to avoid repeated array resizing
        var parts: [String] = []
        parts.reserveCapacity(8)

        parts.append("""
You are a synthesis engine. Your ONLY job is to find non-obvious connections across the user's activity domains.

Rules:
- Only report connections that span 2+ DIFFERENT domains (different apps, data sources, or time periods)
- Only report connections the user is UNLIKELY to have noticed themselves
- If nothing genuinely surprising exists, return an empty array []
- Do NOT report: same-app connections, trivial observations, things being actively worked on right now, or obvious relationships
- Maximum 3 connections
""")

        if !snapshot.currentApp.isEmpty {
            parts.append("CURRENT ACTIVITY:\n\(snapshot.currentActivity)")
        }

        if !snapshot.thoughtSummaries.isEmpty {
            parts.append("RECENT SCREEN CONTEXT:\n\(snapshot.thoughtSummaries.prefix(15).joined(separator: "\n"))")
        }

        if !snapshot.relevantMemories.isEmpty {
            parts.append("STORED MEMORIES:\n\(snapshot.relevantMemories.prefix(20).joined(separator: "\n"))")
        }

        if !snapshot.activeGoals.isEmpty {
            parts.append("ACTIVE GOALS:\n\(snapshot.activeGoals.joined(separator: "\n"))")
        }

        if !snapshot.recentFiles.isEmpty {
            parts.append("RECENT FILES IN DOWNLOADS:\n\(snapshot.recentFiles.joined(separator: "\n"))")
        }

        if !recentHeadlines.isEmpty {
            parts.append("ALREADY SURFACED (do NOT repeat):\n- \(recentHeadlines.suffix(10).joined(separator: "\n- "))")
        }

        parts.append("""
Respond with ONLY a JSON array:
[{"headline":"...","explanation":"2-3 sentences","domains":["d1","d2"],"surprise_score":0.7,"action":"optional or null"}]
If nothing surprising: []
""")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - LLM Call

    private func callLLM(prompt: String) async -> String? {
        let messages = [
            ChatMessage(role: "user", content: prompt, tool_calls: nil, tool_call_id: nil, reasoning_content: nil)
        ]

        do {
            let service = await LLMServiceManager.shared.currentService
            let response = try await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 600)
            return response.text
        } catch {
            print("[SynthesisEngine] LLM call failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Parsing

    func parseInsights(from text: String, snapshot: Snapshot) -> [SynthesisInsight] {
        var jsonStr = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON array from potential markdown fences
        guard let startIdx = jsonStr.firstIndex(of: "["),
              let endIdx = jsonStr.lastIndex(of: "]"),
              startIdx <= endIdx
        else {
            if jsonStr.contains("[]") { return [] }
            print("[SynthesisEngine] Failed to parse: \(text.prefix(200))")
            return []
        }
        jsonStr = String(jsonStr[startIdx...endIdx])

        guard let data = jsonStr.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let sourceSnapshot = SynthesisInsight.SourceSnapshot(
            thoughtSummaries: Array(snapshot.thoughtSummaries.prefix(5)),
            relevantMemories: Array(snapshot.relevantMemories.prefix(5)),
            activeGoals: snapshot.activeGoals,
            recentFiles: snapshot.recentFiles
        )

        return jsonArray.compactMap { json -> SynthesisInsight? in
            guard let headline = json["headline"] as? String,
                  let explanation = json["explanation"] as? String,
                  let domains = json["domains"] as? [String], domains.count >= 2,
                  let surpriseScore = json["surprise_score"] as? Double
            else { return nil }

            let action = json["action"] as? String
            return SynthesisInsight(
                id: UUID(),
                headline: headline,
                explanation: explanation,
                domains: domains,
                surpriseScore: surpriseScore,
                actionSuggestion: (action == nil || action == "null") ? nil : action,
                createdAt: Date(),
                sourceData: sourceSnapshot
            )
        }
    }

    // MARK: - Deduplication (pre-computed word sets)

    private func deduplicateInsights(_ insights: [SynthesisInsight]) -> [SynthesisInsight] {
        insights.filter { !isAlreadySurfaced($0.headline) }
    }

    private func isAlreadySurfaced(_ headline: String) -> Bool {
        let words = Set(headline.lowercased().split(separator: " ").map(String.init))
        for existingWords in recentHeadlineWords {
            let intersection = words.intersection(existingWords)
            let union = words.union(existingWords)
            if !union.isEmpty && Double(intersection.count) / Double(union.count) > 0.5 {
                return true
            }
        }
        return false
    }

    private func addToRecentHeadlines(_ headline: String) {
        recentHeadlines.append(headline)
        recentHeadlineWords.append(Set(headline.lowercased().split(separator: " ").map(String.init)))
        if recentHeadlines.count > maxRecentHeadlines {
            recentHeadlines.removeFirst()
            recentHeadlineWords.removeFirst()
        }
    }

    // MARK: - Persistence (cached, append-only)

    private func appendInsights(_ insights: [SynthesisInsight]) {
        cachedInsights.append(contentsOf: insights)

        // Write full cache to disk
        if let data = try? JSONEncoder().encode(cachedInsights) {
            try? data.write(to: Self.todayFileURL, options: .atomic)
        }

        // Add headlines to dedup index
        for insight in insights {
            addToRecentHeadlines(insight.headline)
        }

        // Prune old files once per day
        let today = Self.dateFormatter.string(from: Date())
        if lastPruneDate != today {
            lastPruneDate = today
            pruneOldFiles()
        }
    }

    private func loadCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true

        guard let data = try? Data(contentsOf: Self.todayFileURL),
              let insights = try? JSONDecoder().decode([SynthesisInsight].self, from: data)
        else { return }

        cachedInsights = insights
        recentHeadlines = insights.map(\.headline)
        recentHeadlineWords = insights.map {
            Set($0.headline.lowercased().split(separator: " ").map(String.init))
        }
    }

    private func pruneOldFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86400)

        guard let files = try? fm.contentsOfDirectory(atPath: Self.storeDir.path) else { return }
        for file in files where file.hasSuffix(".json") {
            let dateStr = file.replacingOccurrences(of: ".json", with: "")
            if let date = Self.dateFormatter.date(from: dateStr), date < cutoff {
                try? fm.removeItem(at: Self.storeDir.appendingPathComponent(file))
            }
        }
    }

    // MARK: - Daily Counter

    private func resetDailyCounterIfNeeded() {
        let today = Self.dateFormatter.string(from: Date())
        if surfacedTodayDate != today {
            surfacedToday = 0
            surfacedTodayDate = today
            cachedInsights = []
            cacheLoaded = false
            loadCache()
        }
    }
}
