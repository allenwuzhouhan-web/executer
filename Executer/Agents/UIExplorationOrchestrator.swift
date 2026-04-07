import Foundation
import AppKit

/// Orchestrates overnight UI exploration across multiple apps.
/// Selects apps to explore, runs headless LLM-guided exploration for each,
/// respects per-provider yuan budgets (hard stop), and collects results.
///
/// Integrates into OvernightAgent as Phase 3 (after synthesis, before task discovery).
enum UIExplorationOrchestrator {

    // MARK: - Configuration

    struct Config {
        var timeBudgetMinutes: Int = 120
        var deepseekBudgetYuan: Double = 5.0
        var kimiBudgetYuan: Double = 5.0
        var maxApps: Int = 5
        var maxIterationsPerApp: Int = 20

        /// Apps to never explore (system, sensitive, dev tools).
        static let defaultSkipList: Set<String> = [
            "Finder", "SystemUIServer", "Dock", "loginwindow", "Spotlight",
            "Terminal", "iTerm2", "Xcode", "Activity Monitor", "System Settings",
            "System Preferences", "Keychain Access", "Executer", "Console",
            "Disk Utility", "Migration Assistant", "Installer", "Script Editor",
            "Automator", "Boot Camp Assistant", "AirPort Utility",
            "Font Book", "ColorSync Utility", "Screenshot",
        ]
    }

    // MARK: - Result Types

    struct ExplorationResult {
        let appsExplored: [AppResult]
        let totalElementsLearned: Int
        let costSummary: [(provider: String, yuan: Double)]
        let durationSeconds: Int
    }

    struct AppResult {
        let appName: String
        let elementsExplored: Int
        let elementsLearned: Int
        let sectionsVisited: [String]
        let stoppedReason: String  // "complete", "budget", "time", "error"
    }

    // MARK: - App Selection

    private struct AppTarget {
        let name: String
        let isRunning: Bool
        let score: Double  // higher = more worth exploring
    }

    /// Select apps to explore, ranked by how much there is to learn.
    private static func selectApps(config: Config) -> [AppTarget] {
        // Get running GUI apps
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty && !Config.defaultSkipList.contains($0) }

        // Get apps from learning database (recently observed)
        let dbApps = LearningDatabase.shared.allAppNames()

        // Score each app: more observations + less UI knowledge = higher score
        var scored: [String: AppTarget] = [:]

        for app in runningApps {
            let knowledgeCount = LearningDatabase.shared.queryUIKnowledge(forApp: app, limit: 1000).count
            // Running apps get base score of 10, penalized by existing knowledge
            let score = 10.0 / Double(knowledgeCount + 1) * 2.0  // 2x boost for running
            scored[app] = AppTarget(name: app, isRunning: true, score: score)
        }

        for dbApp in dbApps {
            let app = dbApp.name
            if Config.defaultSkipList.contains(app) { continue }
            if scored[app] != nil { continue }  // already scored as running

            let knowledgeCount = LearningDatabase.shared.queryUIKnowledge(forApp: app, limit: 1000).count
            let observationScore = Double(dbApp.observationCount)
            let score = observationScore / Double(knowledgeCount + 1)
            scored[app] = AppTarget(name: app, isRunning: false, score: score)
        }

        // Sort by score descending, take top N
        return scored.values
            .sorted { $0.score > $1.score }
            .prefix(config.maxApps)
            .map { $0 }
    }

    // MARK: - Main Entry Point

    /// Run an exploration session. Called from OvernightAgent Phase 3.
    static func runSession(config: Config = Config()) async -> ExplorationResult {
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(Double(config.timeBudgetMinutes) * 60)
        var appResults: [AppResult] = []
        var totalLearned = 0

        let apps = selectApps(config: config)
        guard !apps.isEmpty else {
            print("[UIExplorer] No apps to explore")
            return ExplorationResult(
                appsExplored: [],
                totalElementsLearned: 0,
                costSummary: CostTracker.shared.sessionCostSummary(),
                durationSeconds: 0
            )
        }

        print("[UIExplorer] Selected \(apps.count) apps: \(apps.map { $0.name }.joined(separator: ", "))")

        for app in apps {
            // Budget check — hard stop if either provider is over budget
            let currentProvider = LLMServiceManager.shared.currentProvider.rawValue
            if CostTracker.shared.isOverSessionBudget(provider: "deepseek", budgetYuan: config.deepseekBudgetYuan) {
                print("[UIExplorer] DeepSeek budget exceeded (\(String(format: "%.2f", CostTracker.shared.sessionCostYuan(provider: "deepseek"))) yuan)")
                break
            }
            if CostTracker.shared.isOverSessionBudget(provider: "kimi", budgetYuan: config.kimiBudgetYuan) ||
               CostTracker.shared.isOverSessionBudget(provider: "kimicn", budgetYuan: config.kimiBudgetYuan) {
                print("[UIExplorer] Kimi budget exceeded")
                break
            }

            // Time check
            if Date() >= deadline {
                print("[UIExplorer] Time budget exceeded")
                break
            }

            // Explore this app
            let result = await exploreApp(
                name: app.name,
                isRunning: app.isRunning,
                maxIterations: config.maxIterationsPerApp,
                deadline: deadline,
                config: config
            )
            appResults.append(result)
            totalLearned += result.elementsLearned

            print("[UIExplorer] \(app.name): \(result.elementsLearned) new elements (\(result.stoppedReason))")

            // Brief pause between apps to let UI settle
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let duration = Int(Date().timeIntervalSince(startTime))
        return ExplorationResult(
            appsExplored: appResults,
            totalElementsLearned: totalLearned,
            costSummary: CostTracker.shared.sessionCostSummary(),
            durationSeconds: duration
        )
    }

    // MARK: - Per-App Exploration

    private static func exploreApp(
        name: String,
        isRunning: Bool,
        maxIterations: Int,
        deadline: Date,
        config: Config
    ) async -> AppResult {
        // Count existing knowledge before exploration
        let knowledgeBefore = LearningDatabase.shared.queryUIKnowledge(forApp: name, limit: 1000).count

        // Switch to the app (launch if not running)
        do {
            if isRunning {
                _ = try await SwitchToAppTool().execute(arguments: "{\"app_name\": \"\(name)\"}")
            } else {
                _ = try await LaunchAppTool().execute(arguments: "{\"app_name\": \"\(name)\"}")
            }
        } catch {
            print("[UIExplorer] Failed to switch to \(name): \(error)")
            return AppResult(appName: name, elementsExplored: 0, elementsLearned: 0,
                             sectionsVisited: [], stoppedReason: "error: \(error.localizedDescription)")
        }

        // Wait for app to settle
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Build the exploration prompt
        let existingKnowledge = LearningDatabase.shared.queryUIKnowledge(forApp: name, limit: 50)
        let knownList = existingKnowledge.isEmpty ? "None yet — this is a fresh exploration!" :
            existingKnowledge.map { "- \($0.actionType) \"\($0.elementLabel)\" in \"\($0.sectionPath)\" → \($0.resultDescription)" }
                .joined(separator: "\n")

        let explorationPrompt = buildExplorationPrompt(
            appName: name,
            knownElements: knownList,
            maxIterations: maxIterations
        )

        // Run headless agent via BackgroundAgentManager
        let lifetimeMinutes = max(5, maxIterations / 3)  // rough estimate: ~20s per iteration
        let agentResult: BackgroundAgent? = await MainActor.run {
            BackgroundAgentManager.shared.startAgent(
                goal: explorationPrompt,
                trigger: .oneShot(command: explorationPrompt),
                maxLifetimeMinutes: lifetimeMinutes
            )
        }
        guard let agent = agentResult else {
            return AppResult(appName: name, elementsExplored: 0, elementsLearned: 0,
                             sectionsVisited: [], stoppedReason: "error: could not start agent")
        }

        let timeoutSeconds = lifetimeMinutes * 60
        let agentId = agent.id
        let _ = await BackgroundAgentManager.shared.waitForAgent(
            id: agentId,
            timeoutSeconds: timeoutSeconds
        )

        // Count knowledge after
        let knowledgeAfter = LearningDatabase.shared.queryUIKnowledge(forApp: name, limit: 1000)
        let newEntries = knowledgeAfter.count - knowledgeBefore
        let sections = Array(Set(knowledgeAfter.map { $0.sectionPath }.filter { !$0.isEmpty }))

        // Determine stop reason
        let stoppedReason: String
        if CostTracker.shared.isOverSessionBudget(provider: "deepseek", budgetYuan: config.deepseekBudgetYuan) ||
           CostTracker.shared.isOverSessionBudget(provider: "kimi", budgetYuan: config.kimiBudgetYuan) ||
           CostTracker.shared.isOverSessionBudget(provider: "kimicn", budgetYuan: config.kimiBudgetYuan) {
            stoppedReason = "budget"
        } else if Date() >= deadline {
            stoppedReason = "time"
        } else {
            stoppedReason = "complete"
        }

        return AppResult(
            appName: name,
            elementsExplored: knowledgeAfter.count,
            elementsLearned: max(0, newEntries),
            sectionsVisited: sections,
            stoppedReason: stoppedReason
        )
    }

    // MARK: - Exploration Prompt

    private static func buildExplorationPrompt(appName: String, knownElements: String, maxIterations: Int) -> String {
        """
        You are exploring \(appName)'s UI overnight to learn what each button and element does.
        The user is sleeping — do NOT modify any data, settings, or send any messages.

        ALREADY KNOWN (skip these, focus on undiscovered areas):
        \(knownElements)

        EXPLORATION STRATEGY:
        1. First, use perceive_screen to see what's currently on screen.
        2. Explore the menu bar: click each top-level menu (File, Edit, View, etc.) to see its items, then press Escape to close.
        3. Explore toolbar buttons and sidebar items using explore_ui with mode=single for important-looking elements.
        4. Use explore_ui with mode=scan to bulk-discover all visible interactive elements.
        5. Open Preferences/Settings (hotkey cmd+,) and scan each panel to learn what settings exist.
        6. Scroll down if there's more content below, then explore the newly visible elements.
        7. When all main UI areas have been explored, say "Exploration complete for \(appName)."

        SAFETY RULES (CRITICAL):
        - NEVER click elements labeled: delete, remove, logout, quit, close, trash, send, submit, save, apply, purchase, buy
        - ALWAYS press Escape after opening menus or dialogs to close them before moving on
        - Do NOT type into any text fields
        - Do NOT toggle switches or modify settings
        - If something unexpected happens (dialog, error), press Escape immediately and move on
        - If an action seems to modify data, press cmd+z to undo immediately

        BUDGET: You have \(maxIterations) steps total. Be efficient — don't repeat yourself.
        When done, respond with text only (no tool calls) to signal completion.
        """
    }
}
