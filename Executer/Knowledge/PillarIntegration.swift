// WIP: Pillar integration — depends on modules not yet in build (Organizer, Radar, MorningConsole)
// Disabled until those modules are ready for compilation.
#if PILLAR_ENABLED
import Foundation
import AppKit

// MARK: - Tool Registration Extension

/// Registers all new pillar tools into the existing ToolRegistry.
/// Called from AppDelegate after initial setup.
enum PillarIntegration {

    /// Register all 10-pillar tools into the global registry.
    /// Call this once during app startup.
    static func registerTools() {
        let newTools: [any ToolDefinition] = [
            // Project Mind Map
            ListProjectsTool(),
            GetProjectTool(),
            UpdateProjectTool(),
            LinkFileToProjectTool(),
            // Semantic File Organizer
            OrganizeFileTool(),
            GetOrganizationSuggestionsTool(),
            // Work Completion Engine
            CompleteWorkTool(),
            AnalyzeCompletionStatusTool(),
            // Universal Content Factory
            CreateContentTool(),
        ]

        // Register each tool
        for tool in newTools {
            ToolRegistry.shared.registerPillarTool(tool)
        }
        print("[PillarIntegration] Registered \(newTools.count) pillar tools")
    }

    /// Start all autonomous background services.
    static func startServices() {
        // Bootstrap Project Mind Map — scan filesystem for projects
        Task.detached(priority: .utility) {
            await ProjectMindMap.shared.refreshFromDisk()
        }

        // Start Information Radar — background monitoring
        Task.detached(priority: .utility) {
            await InformationRadar.shared.start()
        }

        // Wire FileMonitor → autonomous systems
        FileMonitor.shared.onAutonomousFileEvent = { event in
            Task {
                await InformationRadar.shared.handleFileEvent(
                    directory: event.directory,
                    fileExtension: event.fileExtension,
                    eventType: event.eventType.rawValue
                )
                await ProjectMindMap.shared.handleFileEvent(path: event.directory)
            }
        }

        // Morning Console on overnight agent completion
        NotificationCenter.default.addObserver(
            forName: .morningConsoleReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let window = MorningConsoleWindow()
                window.show()
            }
        }
    }
}

// MARK: - ToolRegistry Extension for Dynamic Registration

extension ToolRegistry {
    /// Register a single tool dynamically (used by pillar integration).
    func registerPillarTool(_ tool: any ToolDefinition) {
        // Use the existing registerMCPTools pattern but for a single tool
        registerMCPTools([tool])
    }
}

// MARK: - Safety Classification Extension

extension ToolSafetyClassifier {
    /// Extended tier lookup that includes pillar tools.
    static let pillarTiers: [String: ToolRiskTier] = [
        // Project Mind Map
        "list_projects": .safe, "get_project": .safe,
        "update_project": .normal, "link_file_to_project": .normal,
        // Semantic File Organizer
        "organize_file": .elevated, "get_organization_suggestions": .safe,
        // Work Completion Engine
        "complete_work": .elevated, "analyze_completion_status": .safe,
        // Content Factory
        "create_content": .elevated,
    ]

    /// Returns the risk tier for a tool, checking pillar tools first.
    static func pillarTier(for toolName: String) -> ToolRiskTier? {
        pillarTiers[toolName]
    }
}

// MARK: - LLM System Prompt Extension

extension ProjectMindMap {
    /// Quick access to the prompt section for system prompt composition.
    nonisolated static var systemPromptSection: String {
        promptSection
    }
}

// MARK: - Intent Engine Integration for OvernightAgent

extension IntentEngine {
    /// Replacement for hardcoded OvernightJobRunner.runAllJobs().
    /// Returns a JobRunResult compatible with existing pipeline.
    func runDynamicJobs() async -> JobRunResult {
        let dynamicJobs = await generateJobs()

        if dynamicJobs.isEmpty {
            // Fallback to legacy
            return await OvernightJobRunner.runAllJobs()
        }

        let startTime = Date()
        var results: [JobResult] = []
        for job in dynamicJobs {
            let result = await job.runner()
            results.append(result)
        }
        return JobRunResult(
            jobs: results,
            totalDuration: Date().timeIntervalSince(startTime),
            startTime: startTime
        )
    }

    /// Replacement for TaskDiscoveryEngine.shared.discoverTasks().
    func discoverTasksWithFallback() async -> [OvernightTask] {
        let discovered = await discoverTasks()
        if !discovered.isEmpty { return discovered }
        // Fallback to legacy scanner
        return await TaskDiscoveryEngine.shared.discoverTasks()
    }
}

// MARK: - Adaptive Notifier Integration

extension OutputRouter {
    /// Route through AdaptiveNotifier instead of direct notification.
    static func routeViaNotifier(_ report: OvernightReport) async {
        report.saveToDisk()
        let summary = report.toNotificationSummary()
        await AdaptiveNotifier.shared.deliver(
            title: "Overnight Agent Complete",
            body: summary,
            urgency: 0.7,
            source: "overnight_agent"
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: .overnightReportReady,
                object: nil,
                userInfo: ["report": report]
            )
            NotificationCenter.default.post(name: .morningConsoleReady, object: nil)
        }
    }
}

// MARK: - Trust Ratchet Integration with SecurityGateway

extension SecurityGateway {
    /// Check if Trust Ratchet allows bypassing LLM risk assessment for this tool.
    func trustRatchetAllowsExecution(toolName: String) -> Bool {
        TrustRatchet.canBypassRiskAssessment(toolName: toolName, domain: "global")
    }
}

// MARK: - CoworkingSuggestionPipeline Radar Integration

extension InformationRadar {
    /// Get the most urgent pending signal for suggestion pipeline.
    func topUrgentSignal() async -> RadarSignal? {
        let urgent = await urgentSignals(threshold: 0.7)
        return urgent.last
    }
}
#endif // PILLAR_ENABLED
