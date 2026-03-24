import Foundation

/// Central registry of all tools the LLM can invoke.
class ToolRegistry {
    static let shared = ToolRegistry()

    private let tools: [String: ToolDefinition]
    // Cached schema array — avoids 220+ AnyCodable allocations per API call (~500KB saved)
    private let cachedSchemas: [[String: AnyCodable]]

    private init() {
        let allTools: [ToolDefinition] = [
            // App Control
            LaunchAppTool(),
            QuitAppTool(),
            ForceQuitAppTool(),
            SwitchToAppTool(),
            HideAppTool(),
            ListRunningAppsTool(),

            // Music
            MusicPlayTool(),
            MusicPauseTool(),
            MusicNextTool(),
            MusicPreviousTool(),
            MusicCatalogSearchTool(),
            MusicPlaySongTool(),
            MusicGetCurrentTool(),
            MusicSetVolumeTool(),
            MusicToggleShuffleTool(),

            // System Settings
            SetVolumeTool(),
            MuteVolumeTool(),
            UnmuteVolumeTool(),
            GetVolumeTool(),
            SetBrightnessTool(),
            GetBrightnessTool(),
            ToggleDarkModeTool(),
            GetDarkModeTool(),
            ToggleNightShiftTool(),
            ToggleDNDTool(),
            ToggleWiFiTool(),
            ToggleBluetoothTool(),

            // Power
            LockScreenTool(),
            SleepDisplayTool(),
            SleepSystemTool(),
            ShutdownTool(),
            RestartTool(),
            PreventSleepTool(),
            LogOutTool(),

            // Files
            FindFilesTool(),
            OpenFileTool(),
            OpenFileWithAppTool(),
            MoveFileTool(),
            CopyFileTool(),
            TrashFileTool(),
            CreateFolderTool(),
            GetFileInfoTool(),
            RevealInFinderTool(),
            GetDownloadsPathTool(),

            // Web
            OpenURLTool(),
            SearchWebTool(),
            OpenInSafariTool(),
            GetSafariURLTool(),
            GetSafariTitleTool(),
            GetChromeURLTool(),
            NewSafariTabTool(),

            // Window Management
            ListWindowsTool(),
            MoveWindowTool(),
            ResizeWindowTool(),
            FullscreenWindowTool(),
            MinimizeWindowTool(),
            TileWindowLeftTool(),
            TileWindowRightTool(),
            TileWindowTopLeftTool(),
            CenterWindowTool(),
            CloseWindowTool(),

            // Productivity
            CreateReminderTool(),
            CreateCalendarEventTool(),
            CreateNoteTool(),
            SetTimerTool(),
            OpenSystemPreferencesTool(),

            // Terminal
            RunShellCommandTool(),
            OpenTerminalTool(),
            OpenTerminalWithCommandTool(),

            // Screenshot
            CaptureScreenTool(),
            CaptureWindowTool(),

            // Clipboard
            GetClipboardTextTool(),
            SetClipboardTextTool(),
            GetClipboardImageTool(),

            // Notifications & Speech
            ShowNotificationTool(),
            SpeakTextTool(),

            // Skills (compound workflows)
            ListSkillsTool(),
            SaveSkillTool(),
            RemoveSkillTool(),

            // Web Content Reading
            ReadSafariPageTool(),
            ReadSafariHTMLTool(),
            FetchURLContentTool(),
            ReadChromePageTool(),

            // File Content (read/write/edit)
            ReadFileTool(),
            WriteFileTool(),
            EditFileTool(),
            ListDirectoryTool(),
            AppendToFileTool(),

            // File Search & Indexing
            SearchFileContentsTool(),
            ReadPDFTextTool(),
            DirectoryTreeTool(),
            FilePreviewTool(),

            // Memory (cross-session)
            SaveMemoryTool(),
            RecallMemoriesTool(),
            ForgetMemoryTool(),
            ListMemoriesTool(),

            // Aliases
            CreateAliasTool(),
            ListAliasesTool(),
            RemoveAliasTool(),

            // Clipboard History
            GetClipboardHistoryTool(),
            SearchClipboardHistoryTool(),
            ClearClipboardHistoryTool(),

            // System Info
            GetSystemInfoTool(),

            // Productivity (Query)
            QueryCalendarEventsTool(),
            QueryRemindersTool(),

            // Screenshot (Enhanced)
            CaptureScreenToClipboardTool(),
            CaptureAreaTool(),
            OCRImageTool(),

            // Window Management (Enhanced)
            TileWindowsSideBySideTool(),
            MoveWindowToSpaceTool(),
            ArrangeWindowsTool(),

            // File Operations (Enhanced)
            BatchRenameFilesTool(),
            FindFilesByAgeTool(),
            GetFinderWindowPathTool(),

            // System Settings (Enhanced)
            ConnectBluetoothDeviceTool(),
            SetDNDDurationTool(),

            // Scheduler
            ScheduleTaskTool(),
            ListScheduledTasksTool(),

            // Weather
            GetWeatherTool(),
            SetWeatherKeyTool(),

            // Automation Rules
            CreateAutomationRuleTool(),
            ListAutomationRulesTool(),
            RemoveAutomationRuleTool(),
            ToggleAutomationRuleTool(),

            // Cursor / Mouse Control
            MoveCursorTool(),
            ClickTool(),
            ClickElementTool(),
            ScrollTool(),
            DragTool(),
            GetCursorPositionTool(),

            // Keyboard / Typing
            TypeTextTool(),
            PressKeyTool(),
            HotkeyTool(),
            SelectAllTextTool(),

            // Dictionary / Language (native macOS — no API)
            DictionaryLookupTool(),
            ThesaurusLookupTool(),
            SpellCheckTool(),
        ]

        var dict: [String: ToolDefinition] = [:]
        dict.reserveCapacity(allTools.count)
        for tool in allTools {
            dict[tool.name] = tool
        }
        self.tools = dict
        self.cachedSchemas = dict.values.map { $0.toAPISchema() }
    }

    /// Returns all tool definitions formatted for the DeepSeek API (OpenAI function calling format).
    func toolDefinitions() -> [[String: AnyCodable]] {
        cachedSchemas
    }

    /// Execute a tool by name with the given JSON arguments string.
    func execute(toolName: String, arguments: String) async throws -> String {
        guard let tool = tools[toolName] else {
            throw ExecuterError.toolNotFound(toolName)
        }
        return try await tool.execute(arguments: arguments)
    }

    /// Get a tool by name.
    func tool(named name: String) -> ToolDefinition? {
        tools[name]
    }

    /// Total number of registered tools.
    var count: Int { tools.count }
}
