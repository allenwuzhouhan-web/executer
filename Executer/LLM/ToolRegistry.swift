import Foundation

/// Tool categories for relevance filtering — only send relevant tools to the LLM per query.
enum ToolCategory: String, CaseIterable {
    case appControl, music, systemSettings, power, files, web, windows
    case productivity, terminal, screenshot, clipboard, notifications
    case skills, webContent, fileContent, fileSearch, memory
    case aliases, clipboardHistory, systemInfo, automation
    case cursor, keyboard, language, scheduler, weather
    case messaging, academicResearch, documents, browser, mcp
}

/// Central registry of all tools the LLM can invoke.
class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: ToolDefinition]
    // Cached schema array — avoids 220+ AnyCodable allocations per API call (~500KB saved)
    private var cachedSchemas: [[String: AnyCodable]]
    // Tool name → category mapping for filtered queries
    private var toolCategories: [String: ToolCategory]
    // Pre-built per-category schema cache
    private var schemasByCategory: [ToolCategory: [[String: AnyCodable]]]

    private init() {
        var allTools: [any ToolDefinition] = [
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
            SetAlarmTool(),
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
            ReadWebPageTool(),
            ReadSafariPageTool(),

            // Safari DOM Interaction (for React/dynamic web apps)
            SafariReadElementsTool(),
            SafariClickTool(),
            SafariTypeTool(),
            SafariSelectTool(),
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

            // Goals (persistent goal stack)
            AddGoalTool(),
            ListGoalsTool(),
            CompleteGoalStepTool(),
            GetNextGoalActionTool(),

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

            // Background Agents
            StartBackgroundAgentTool(),
            ListBackgroundAgentsTool(),
            StopBackgroundAgentTool(),
            SpawnSubAgentTool(),
            CheckAgentStatusTool(),
            WaitForAgentTool(),

            // Email Briefing
            SendEmailBriefingTool(),
            ScheduleEmailBriefingTool(),
            ListEmailBriefingsTool(),
            CancelEmailBriefingTool(),

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

            // Messaging (WeChat, iMessage, WhatsApp)
            SendMessageTool(),
            SendWeChatMessageTool(),
            SendIMessageTool(),
            SendWhatsAppMessageTool(),
            FetchWeChatMessagesTool(),
            ReadMessagesTool(),
            WeChatSentHistoryTool(),

            // News
            FetchNewsTool(),
            SetNewsKeyTool(),

            // Academic Research
            SemanticScholarSearchTool(),
            GetPaperDetailsTool(),
            SetSemanticScholarKeyTool(),

            // Instant Search (DuckDuckGo)
            InstantSearchTool(),

            // Image Search
            SearchImagesTool(),

            // Screen Reading & Learning (Accessibility-based, no screen recording)
            ReadScreenTool(),
            ReadAppTextTool(),
            GetLearnedPatternsTool(),
            ListLearnedAppsTool(),
            GetCurrentSessionTool(),
            GetTodayContextTool(),
            RecallWorkContextTool(),
            GetDailySummaryTool(),
            GetUserGoalsTool(),
            GetCurrentIntentTool(),

            // Phase 4-10: Prediction, Templates, Autonomy
            GetPredictionsTool(),
            GetRoutinesTool(),
            ListWorkflowTemplatesTool(),
            GetAutonomyStatusTool(),
            GetDayPlanTool(),
            CompilePatternTool(),

            // Skill Verification
            VerifySkillNowTool(),
            ListPendingSkillsTool(),
            ApproveSkillTool(),

            // Document Operations
            ReadDocumentTool(),
            CreateDocumentTool(),
            SetupPythonDocsTool(),
            ExtractDocumentStyleTool(),
            ListDocumentStylesTool(),

            // Tool Catalog (on-demand guide lookup)
            GetToolGuideTool(),

            // Meta-tool: request additional tools mid-conversation
            RequestToolsTool(),

            // Skill Import (GitHub discovery + import)
            SearchGitHubSkillsTool(),
            ImportSkillTool(),
            ListSkillSourcesTool(),

            // Browser Automation (browser-use)
            BrowserTaskTool(),
            BrowserExtractTool(),
            BrowserSessionTool(),
            BrowserScreenshotTool(),

            // Browser Intelligence (DOM, JS, network)
            BrowserExecuteJSTool(),
            BrowserReadDOMTool(),
            BrowserGetConsoleTool(),
            BrowserInspectElementTool(),
            BrowserClickElementCSSTool(),
            BrowserTypeInElementTool(),
            BrowserInterceptNetworkTool(),
            BrowserNavigateTool(),

            // Chrome CDP Connection (real browser control)
            BrowserConnectChromeTool(),
            BrowserReadElementsTool(),
            BrowserClickElementTool(),
            BrowserTypeElementTool(),

            // Vision & Screen Perception
            PerceiveScreenTool(),
            PerceiveScreenVisualTool(),
            FindElementTool(),

            // Fast Text Input
            PasteTextTool(),

            // Document Training (8-stage study pipeline)
            TrainDocumentTool(),
            ListTrainedDocumentsTool(),
            RecallTrainedKnowledgeTool(),

            // Document Creation (bundled engines)
            CreatePresentationTool(),
            ExtractPPTDesignTool(),
            CreateWordDocumentTool(),
            CreateSpreadsheetTool(),

            // Mail (macOS Mail.app)
            SearchMailTool(),
            OpenEmailTool(),
            ReadEmailTool(),
            ListMailboxesTool(),
        ]

        // MCP tools are registered asynchronously after server connection.
        // See registerMCPTools() called from AppDelegate after connectAll().

        var dict: [String: ToolDefinition] = [:]
        dict.reserveCapacity(allTools.count)
        for tool in allTools {
            dict[tool.name] = tool
        }
        self.tools = dict
        self.cachedSchemas = dict.values.map { $0.toAPISchema() }

        // Build category mapping
        let categoryMap: [String: ToolCategory] = [
            // App Control
            "launch_app": .appControl, "quit_app": .appControl, "force_quit_app": .appControl,
            "switch_to_app": .appControl, "hide_app": .appControl, "list_running_apps": .appControl,
            // Music
            "music_play": .music, "music_pause": .music, "music_next": .music, "music_previous": .music,
            "music_search": .music, "music_play_song": .music, "music_get_current": .music,
            "music_set_volume": .music, "music_toggle_shuffle": .music,
            // System Settings
            "set_volume": .systemSettings, "mute_volume": .systemSettings, "unmute_volume": .systemSettings,
            "get_volume": .systemSettings, "set_brightness": .systemSettings, "get_brightness": .systemSettings,
            "toggle_dark_mode": .systemSettings, "get_dark_mode": .systemSettings,
            "toggle_night_shift": .systemSettings, "toggle_dnd": .systemSettings,
            "toggle_wifi": .systemSettings, "toggle_bluetooth": .systemSettings,
            "connect_bluetooth_device": .systemSettings, "set_dnd_duration": .systemSettings,
            // Power
            "lock_screen": .power, "sleep_display": .power, "sleep_system": .power,
            "shutdown": .power, "restart": .power, "prevent_sleep": .power, "log_out": .power,
            // Files
            "find_files": .files, "open_file": .files, "open_file_with_app": .files,
            "move_file": .files, "copy_file": .files, "trash_file": .files,
            "create_folder": .files, "get_file_info": .files, "reveal_in_finder": .files,
            "get_downloads_path": .files, "batch_rename_files": .files,
            "find_files_by_age": .files, "get_finder_window_path": .files,
            // Web
            "open_url": .web, "search_web": .web, "open_url_in_safari": .web,
            "get_safari_url": .web, "get_safari_title": .web, "get_chrome_url": .web, "new_safari_tab": .web,
            // Web Content
            "read_web_page": .webContent,
            "read_safari_page": .webContent, "read_safari_html": .webContent,
            "safari_read_elements": .webContent, "safari_click": .webContent,
            "safari_type": .webContent, "safari_select": .webContent,
            "fetch_url_content": .webContent, "read_chrome_page": .webContent,
            // Windows
            "list_windows": .windows, "move_window": .windows, "resize_window": .windows,
            "fullscreen_window": .windows, "minimize_window": .windows,
            "tile_window_left": .windows, "tile_window_right": .windows,
            "tile_window_top_left": .windows, "center_window": .windows, "close_window": .windows,
            "tile_windows_side_by_side": .windows, "move_window_to_space": .windows, "arrange_windows": .windows,
            // Productivity
            "create_reminder": .productivity, "create_calendar_event": .productivity,
            "create_note": .productivity, "set_timer": .productivity, "set_alarm": .productivity,
            "open_system_preferences_pane": .productivity,
            "query_calendar_events": .productivity, "query_reminders": .productivity,
            // Terminal
            "run_shell_command": .terminal, "open_terminal": .terminal, "open_terminal_with_command": .terminal,
            // Screenshot
            "capture_screen": .screenshot, "capture_window": .screenshot,
            "capture_screen_to_clipboard": .screenshot, "capture_area": .screenshot, "ocr_image": .screenshot,
            // Clipboard
            "get_clipboard_text": .clipboard, "set_clipboard_text": .clipboard, "get_clipboard_image": .clipboard,
            // Clipboard History
            "get_clipboard_history": .clipboardHistory, "search_clipboard_history": .clipboardHistory,
            "clear_clipboard_history": .clipboardHistory,
            // Notifications
            "show_notification": .notifications, "speak_text": .notifications,
            // Skills
            "list_skills": .skills, "save_skill": .skills, "remove_skill": .skills,
            // File Content
            "read_file": .fileContent, "write_file": .fileContent, "edit_file": .fileContent,
            "list_directory": .fileContent, "append_to_file": .fileContent,
            // File Search
            "search_file_contents": .fileSearch, "read_pdf_text": .fileSearch,
            "directory_tree": .fileSearch, "file_preview": .fileSearch,
            // Memory
            "save_memory": .memory, "recall_memories": .memory,
            "forget_memory": .memory, "list_memories": .memory,
            // Goals
            "add_goal": .memory, "list_goals": .memory,
            "complete_goal_step": .memory, "get_next_goal_action": .memory,
            // Aliases
            "create_alias": .aliases, "list_aliases": .aliases, "remove_alias": .aliases,
            // System Info
            "get_system_info": .systemInfo,
            // Scheduler
            "schedule_task": .scheduler, "list_scheduled_tasks": .scheduler,
            // Weather
            "get_weather": .weather, "set_weather_key": .weather,
            // Automation
            "create_automation_rule": .automation, "list_automation_rules": .automation,
            "remove_automation_rule": .automation, "toggle_automation_rule": .automation,
            // Background Agents
            "start_background_agent": .automation, "list_background_agents": .automation,
            "stop_background_agent": .automation,
            "spawn_subagent": .automation, "check_agent_status": .automation, "wait_for_agent": .automation,
            // Email Briefing
            "send_email_briefing": .productivity, "schedule_email_briefing": .productivity,
            "list_email_briefings": .productivity, "cancel_email_briefing": .productivity,
            // Cursor
            "move_cursor": .cursor, "click": .cursor, "click_element": .cursor,
            "scroll": .cursor, "drag": .cursor, "get_cursor_position": .cursor,
            // Keyboard
            "type_text": .keyboard, "press_key": .keyboard, "hotkey": .keyboard, "select_all_text": .keyboard,
            // Language
            "dictionary_lookup": .language, "thesaurus_lookup": .language, "spell_check": .language,
            // Messaging
            "send_message": .messaging, "send_wechat_message": .messaging,
            "send_imessage": .messaging, "send_whatsapp_message": .messaging,
            "fetch_wechat_messages": .messaging, "read_messages": .messaging,
            "wechat_sent_history": .messaging,
            // News
            "fetch_news": .academicResearch, "set_news_key": .academicResearch,
            // Academic Research
            "semantic_scholar_search": .academicResearch, "get_paper_details": .academicResearch,
            "instant_search": .webContent, "search_images": .documents,
            // Screen Reading & Learning
            "read_screen": .screenshot, "read_app_text": .screenshot,
            "get_learned_patterns": .memory, "list_learned_apps": .memory,
            "get_current_session": .memory, "get_today_context": .memory,
            "recall_work_context": .memory, "get_daily_summary": .memory,
            "get_user_goals": .memory,
            "get_current_intent": .memory,
            "get_predictions": .memory,
            "get_routines": .memory,
            "list_workflow_templates": .memory,
            "get_autonomy_status": .memory,
            "get_day_plan": .memory,
            "compile_pattern_to_template": .memory,
            "set_semantic_scholar_key": .academicResearch,
            // Skill Verification
            "verify_skill_now": .skills, "list_pending_skills": .skills, "approve_skill": .skills,
            // Documents
            "read_document": .documents, "create_document": .documents, "setup_python_docs": .documents,
            "extract_document_style": .documents, "list_document_styles": .documents,
            "train_document": .documents, "list_trained_documents": .documents, "recall_trained_knowledge": .documents,
            "create_presentation": .documents, "extract_ppt_design": .documents,
            "create_word_document": .documents, "create_spreadsheet": .documents,
            // Tool Catalog
            "get_tool_guide": .skills,
            "request_tools": .skills,
            // Skill Import
            "search_github_skills": .skills, "import_skill": .skills, "list_skill_sources": .skills,
            // Browser Automation
            "browser_task": .browser, "browser_extract": .browser,
            "browser_session": .browser, "browser_screenshot": .browser,
            // Browser Intelligence
            "browser_execute_js": .browser, "browser_read_dom": .browser,
            "browser_get_console": .browser, "browser_inspect_element": .browser,
            "browser_click_element_css": .browser, "browser_type_in_element": .browser,
            "browser_intercept_network": .browser, "browser_navigate": .browser,
            "browser_connect_chrome": .browser, "browser_read_elements": .browser,
            "browser_click_element": .browser, "browser_type_element": .browser,
            // Vision & Perception
            "perceive_screen": .screenshot, "perceive_screen_visual": .screenshot, "find_element": .screenshot,
            // Fast Input
            "paste_text": .keyboard,
            // Mail
            "search_mail": .productivity, "open_email": .productivity,
            "read_email": .productivity, "list_mailboxes": .productivity,
        ]
        self.toolCategories = categoryMap

        // Pre-build per-category schema cache
        var byCat: [ToolCategory: [[String: AnyCodable]]] = [:]
        for (name, tool) in dict {
            let cat = categoryMap[name] ?? .files
            byCat[cat, default: []].append(tool.toAPISchema())
        }
        self.schemasByCategory = byCat
    }

    /// Returns all tool definitions formatted for the DeepSeek API (OpenAI function calling format).
    func toolDefinitions() -> [[String: AnyCodable]] {
        cachedSchemas
    }

    /// Returns tool schemas filtered by an explicit allowlist of tool names.
    /// Used by ComputerUseAgent task profiles to restrict available tools.
    func filteredToolDefinitions(allowlist: Set<String>) -> [[String: AnyCodable]] {
        let schemas = allowlist.compactMap { name -> [String: AnyCodable]? in
            guard let tool = tools[name] else { return nil }
            return tool.toAPISchema()
        }
        print("[ToolRegistry] Filtered to \(schemas.count) tools by allowlist")
        return schemas
    }

    /// Returns only the tool schemas relevant to the given query.
    /// Reduces from 220+ tools to ~30-40, saving ~15K tokens per API call.
    func filteredToolDefinitions(for query: String) -> [[String: AnyCodable]] {
        let categories = classifyQueryIntent(query)
        var schemas: [[String: AnyCodable]] = []
        for cat in categories {
            if let catSchemas = schemasByCategory[cat] {
                schemas.append(contentsOf: catSchemas)
            }
        }
        let count = schemas.count
        print("[ToolRegistry] Filtered to \(count) tools (from \(cachedSchemas.count)) for query")
        // If filtering produced very few tools, expand with common utility categories instead of ALL tools
        if count < 3 {
            let utilityCategories: [ToolCategory] = [.web, .webContent, .files, .fileContent, .terminal, .appControl]
            for cat in utilityCategories {
                if let catSchemas = schemasByCategory[cat], !categories.contains(cat) {
                    schemas.append(contentsOf: catSchemas)
                }
            }
            print("[ToolRegistry] Expanded to \(schemas.count) tools with utility categories")
        }
        return schemas
    }

    /// Returns tool schemas filtered by both agent whitelist AND query intent.
    /// Agent filtering narrows first, then intent filtering narrows further.
    func filteredToolDefinitions(for query: String, agent: AgentProfile) -> [[String: AnyCodable]] {
        // Step 1: If agent has an allowedToolIDs whitelist, restrict to those tools
        let agentSchemas: [[String: AnyCodable]]
        if let allowed = agent.allowedToolIDs {
            agentSchemas = allowed.compactMap { name in
                guard let tool = tools[name] else { return nil }
                return tool.toAPISchema()
            }
            print("[ToolRegistry] Agent '\(agent.id)' whitelist: \(agentSchemas.count) tools")
        } else {
            agentSchemas = cachedSchemas
        }

        // Step 2: Apply intent-based category filtering on the agent-scoped set
        let categories = classifyQueryIntent(query)
        let filtered = agentSchemas.filter { schema in
            guard let fn = schema["function"]?.value as? [String: AnyCodable],
                  let name = fn["name"]?.value as? String,
                  let cat = toolCategories[name] else {
                return true  // Keep tools without a category mapping
            }
            return categories.contains(cat)
        }

        let count = filtered.count
        print("[ToolRegistry] Agent '\(agent.id)' + intent filtered to \(count) tools")
        // Fallback: return agent-scoped set if intent filter was too aggressive
        return count >= 3 ? filtered : agentSchemas
    }

    // MARK: - Intent Classification

    private static let intentKeywords: [(keywords: [String], categories: [ToolCategory])] = [
        (["open", "launch", "quit", "close", "switch to", "app"], [.appControl]),
        (["music", "play", "song", "pause", "next track", "shuffle"], [.music]),
        (["volume", "brightness", "dark mode", "light mode", "wifi", "bluetooth", "night shift", "dnd"], [.systemSettings]),
        (["lock", "sleep", "shutdown", "restart", "log out"], [.power]),
        (["file", "folder", "document", "move", "copy", "trash", "rename", "downloads"], [.files, .fileContent, .fileSearch]),
        (["read", "write", "edit", "create file", "save to"], [.fileContent, .files]),
        (["research", "search", "url", "web", "http", "fetch", "browse", "website"], [.web, .webContent, .browser]),
        (["screen", "screenshot", "capture", "ocr", "look at"], [.screenshot]),
        (["click", "cursor", "scroll", "drag", "tap", "press the"], [.cursor]),
        (["type", "press key", "hotkey", "keyboard", "shortcut", "cmd+"], [.keyboard]),
        (["window", "tile", "arrange", "side by side", "fullscreen", "minimize"], [.windows]),
        (["remind", "calendar", "note", "timer", "event", "meeting", "schedule"], [.productivity, .scheduler]),
        (["mail", "email", "inbox", "mailbox", "unread", "sent me", "from lisa", "from ", "that email"], [.productivity]),
        (["terminal", "shell", "command", "run", "brew", "git", "npm", "pip"], [.terminal]),
        (["define", "definition", "synonym", "spell", "meaning"], [.language]),
        (["weather", "temperature", "forecast"], [.weather]),
        (["automation", "when", "whenever", "rule"], [.automation]),
        (["clipboard", "copied", "paste"], [.clipboard, .clipboardHistory]),
        (["remember", "memory", "recall", "forget"], [.memory]),
        (["alias", "shortcut"], [.aliases]),
        (["system info", "about this mac"], [.systemInfo]),
        (["notification", "announce", "say ", "speak"], [.notifications]),
        (["tell", "text", "message", "msg", "send message", "wechat"], [.messaging]),
        (["news", "headlines", "article"], [.academicResearch]),
        (["paper", "research paper", "scholar", "academic", "semantic scholar"], [.academicResearch]),
        (["document", "presentation", "slide", "pptx", "docx", "xlsx", "powerpoint", "word", "excel", "spreadsheet", "deck", "train", "study", "learn from", "keynote", "pages", "report", "essay", "memo", "letter", "table", "data sheet", "image", "photo", "picture"], [.documents, .files, .fileContent, .terminal]),
        (["fill form", "login", "sign up", "sign in", "book", "order", "purchase", "checkout", "add to cart", "scrape", "automate web", "web form", "submit form", "browser"], [.browser, .web]),
    ]

    // Always include these categories — universally useful
    private static let alwaysIncluded: Set<ToolCategory> = [.memory, .skills, .clipboard]

    func classifyQueryIntent(_ query: String) -> Set<ToolCategory> {
        let lower = query.lowercased()
        var cats = Self.alwaysIncluded

        for entry in Self.intentKeywords {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                for cat in entry.categories { cats.insert(cat) }
            }
        }

        // Web tasks often need browser interaction
        if cats.contains(.web) || cats.contains(.webContent) {
            cats.insert(.cursor)
            cats.insert(.keyboard)
            cats.insert(.browser)
        }

        // If nothing matched beyond always-included, include everything
        if cats.count <= Self.alwaysIncluded.count {
            return Set(ToolCategory.allCases)
        }

        return cats
    }

    /// Register MCP-discovered tools into the registry (called after server connection).
    func registerMCPTools(_ mcpTools: [any ToolDefinition]) {
        for tool in mcpTools {
            tools[tool.name] = tool
            toolCategories[tool.name] = .mcp
        }
        // Rebuild schema caches
        cachedSchemas = tools.values.map { $0.toAPISchema() }
        var byCategory: [ToolCategory: [[String: AnyCodable]]] = [:]
        for (name, tool) in tools {
            let cat = toolCategories[name] ?? .files
            byCategory[cat, default: []].append(tool.toAPISchema())
        }
        schemasByCategory = byCategory
        print("[ToolRegistry] Registered \(mcpTools.count) MCP tools, total: \(tools.count)")
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

    /// Execute a tool directly by name — used by SecurityGateway after permission checks.
    func executeDirectly(toolName: String, arguments: String) async throws -> String {
        try await execute(toolName: toolName, arguments: arguments)
    }

    /// Returns the API schema for a single tool, or nil if not found.
    func singleToolSchema(_ name: String) -> [[String: AnyCodable]]? {
        guard let tool = tools[name] else { return nil }
        return [tool.toAPISchema()]
    }

    /// Returns all registered tool names.
    func allToolNames() -> [String] {
        return Array(tools.keys).sorted()
    }

    /// Total number of registered tools.
    var count: Int { tools.count }
}

/// Meta-tool: request additional tools mid-conversation.
/// When the LLM needs a tool that wasn't in the filtered set, it calls this.
/// Returns matching tool names + descriptions so the LLM can ask for them.
struct RequestToolsTool: ToolDefinition {
    let name = "request_tools"
    let description = "Request additional tools that aren't currently available. Use this when you need a tool that wasn't provided. Describe what you need and I'll find matching tools."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "need": JSONSchema.string(description: "What capability you need (e.g., 'click on UI element', 'create a file', 'send a message')"),
        ], required: ["need"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let need = try requiredString("need", from: args).lowercased()

        // Search all tools by name and description
        let allTools = ToolRegistry.shared.allToolNames()
        var matches: [(name: String, description: String)] = []

        for toolName in allTools {
            if let tool = ToolRegistry.shared.tool(named: toolName) {
                let nameLower = toolName.lowercased()
                let descLower = tool.description.lowercased()
                if nameLower.contains(need) || descLower.contains(need) ||
                   need.split(separator: " ").contains(where: { nameLower.contains($0) || descLower.contains($0) }) {
                    matches.append((toolName, String(tool.description.prefix(100))))
                }
            }
        }

        guard !matches.isEmpty else {
            return "No matching tools found for '\(need)'. Try a different description."
        }

        var result = "Available tools matching '\(need)':\n"
        for match in matches.prefix(10) {
            result += "- **\(match.name)**: \(match.description)\n"
        }
        result += "\nYou can now call any of these tools directly."
        return result
    }
}
