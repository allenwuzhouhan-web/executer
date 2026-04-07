import Foundation

/// Bootstraps the 10-pillar autonomous systems: tools, radar, mind map, morning console.
enum AutonomousPillarBootstrap {

    private static var morningConsoleObserver: NSObjectProtocol?

    static func initialize() {
        // Register pillar tools into the global registry
        let tools: [any ToolDefinition] = [
            ListProjectsTool(), GetProjectTool(), UpdateProjectTool(), LinkFileToProjectTool(),
            OrganizeFileTool(), GetOrganizationSuggestionsTool(),
            CompleteWorkTool(), AnalyzeCompletionStatusTool(),
            CreateContentTool(),
        ]
        ToolRegistry.shared.registerMCPTools(tools)
        print("[Pillars] Registered \(tools.count) autonomous tools")

        // Bootstrap Project Mind Map — scan filesystem for projects
        Task.detached(priority: .utility) {
            await ProjectMindMap.shared.refreshFromDisk()
        }

        // Start Information Radar — background monitoring of email/calendar/news
        Task.detached(priority: .utility) {
            await InformationRadar.shared.start()
        }

        // Chain into existing FileMonitor callback for autonomous file processing
        let existingHandler = FileMonitor.shared.onFileEvent
        FileMonitor.shared.onFileEvent = { event in
            existingHandler?(event)
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
        morningConsoleObserver = NotificationCenter.default.addObserver(
            forName: .morningConsoleReady,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let window = MorningConsoleWindow()
                window.show()
            }
        }
    }
}
