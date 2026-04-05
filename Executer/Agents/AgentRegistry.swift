import Foundation

/// Loads, caches, and hot-reloads agent profiles from disk.
final class AgentRegistry {
    static let shared = AgentRegistry()

    private(set) var profiles: [AgentProfile] = []
    @Published private(set) var activeProfile: AgentProfile = .general

    private let agentsDir: URL
    private var fileWatcher: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.executer.agentregistry", qos: .utility)

    // Pre-computed keyword sets per agent for fast routing
    private(set) var keywordIndex: [String: Set<String>] = [:]  // agentId → lowercased keywords

    private init() {
        let appSupport = URL.applicationSupportDirectory
        agentsDir = appSupport.appendingPathComponent("Executer/agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        exportBuiltInProfilesIfNeeded()
        reload()
        startWatching()
        print("[AgentRegistry] Loaded \(profiles.count) agent profiles")
    }

    // MARK: - Public API

    func profile(for id: String) -> AgentProfile? {
        profiles.first { $0.id == id }
    }

    func allProfiles() -> [AgentProfile] {
        profiles
    }

    func setActive(_ id: String) {
        if let p = profile(for: id) {
            activeProfile = p
            print("[AgentRegistry] Active agent → \(p.displayName)")
        }
    }

    func addCustom(_ profile: AgentProfile) throws {
        guard !profile.isBuiltIn else { return }
        try saveProfile(profile)
        reload()
    }

    func removeCustom(_ id: String) throws {
        guard let p = profile(for: id), !p.isBuiltIn else { return }
        let url = agentsDir.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: url)
        if activeProfile.id == id { setActive("general") }
        reload()
    }

    func updateProfile(_ profile: AgentProfile) async throws {
        // Require biometric authentication for profile edits
        let authenticated = await BiometricGate.authenticate(reason: "Modify agent profile '\(profile.displayName)'")
        guard authenticated else {
            print("[AgentRegistry] Profile edit denied — authentication failed")
            return
        }
        try saveProfile(profile)
        if activeProfile.id == profile.id {
            activeProfile = profile
        }
        reload()
    }

    // MARK: - Loading

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder()
        var loaded: [AgentProfile] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? decoder.decode(AgentProfile.self, from: data) else {
                print("[AgentRegistry] Failed to decode \(file.lastPathComponent)")
                continue
            }
            loaded.append(profile)
        }

        // Ensure general always exists
        if !loaded.contains(where: { $0.id == "general" }) {
            loaded.insert(.general, at: 0)
        }

        // Sort: general first, then built-in, then custom alphabetically
        loaded.sort { a, b in
            if a.id == "general" { return true }
            if b.id == "general" { return false }
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.displayName < b.displayName
        }

        profiles = loaded
        rebuildKeywordIndex()

        // Refresh active profile if it was reloaded
        if let refreshed = profile(for: activeProfile.id) {
            activeProfile = refreshed
        }
    }

    // MARK: - Keyword Index

    private func rebuildKeywordIndex() {
        var index: [String: Set<String>] = [:]
        for p in profiles {
            index[p.id] = Set(p.keywords.map { $0.lowercased() })
        }
        keywordIndex = index
    }

    // MARK: - File Watching

    private func startWatching() {
        let fd = open(agentsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.reload()
            print("[AgentRegistry] Profiles reloaded (file change detected)")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    // MARK: - Persistence

    private func saveProfile(_ profile: AgentProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        let url = agentsDir.appendingPathComponent("\(profile.id).json")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Built-in Export

    private func exportBuiltInProfilesIfNeeded() {
        let builtInNames = ["general", "chem", "dev", "daily", "coworking"]
        let fm = FileManager.default

        for name in builtInNames {
            let dest = agentsDir.appendingPathComponent("\(name).json")
            if fm.fileExists(atPath: dest.path) { continue }

            // Load from bundle
            if let bundleURL = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "BuiltInProfiles") {
                try? fm.copyItem(at: bundleURL, to: dest)
            } else {
                // Fallback: generate from code
                if let profile = Self.builtInProfile(name) {
                    try? saveProfile(profile)
                }
            }
        }
    }

    private static func builtInProfile(_ id: String) -> AgentProfile? {
        switch id {
        case "general":
            return .general

        case "chem":
            return AgentProfile(
                id: "chem",
                displayName: "Chemistry",
                systemPromptOverride: """
                    You are an expert chemistry and science tutor. You help with AP Chemistry, \
                    biochemistry, organic chemistry, and scientific research. Be precise with \
                    formulas, units, and significant figures. Use proper chemical notation (subscripts, \
                    superscripts, arrows). When returning molecular data or properties, prefer \
                    structured tables.
                    """,
                allowedToolIDs: [
                    "instant_search", "search_web", "fetch_url_content",
                    "semantic_scholar_search", "get_paper_details",
                    "read_file", "write_file", "run_shell_command",
                    "get_clipboard_text", "set_clipboard_text",
                    "speak_text", "show_notification",
                    "save_memory", "recall_memories",
                    "train_document", "list_trained_documents", "recall_trained_knowledge",
                    "read_document",
                    "request_tools"
                ],
                memoryNamespace: "chem",
                modelOverride: nil,
                maxTokenBudget: nil,
                color: "#4CAF50",
                icon: "flask.fill",
                isBuiltIn: true,
                keywords: [
                    "chemistry", "molecule", "reaction", "compound", "element",
                    "molar", "pH", "bond", "organic", "acid", "base", "synthesis",
                    "enthalpy", "entropy", "equilibrium", "oxidation", "reduction",
                    "electron", "proton", "ion", "isotope", "catalyst", "titration",
                    "stoichiometry", "molarity", "concentration", "precipitate",
                    "solubility", "formula", "atomic", "periodic table",
                    "biochemistry", "protein", "enzyme", "DNA", "RNA",
                    "biology", "cell", "organism", "physics", "quantum",
                    "thermodynamics", "kinetics", "spectroscopy"
                ]
            )

        case "dev":
            return AgentProfile(
                id: "dev",
                displayName: "Developer",
                systemPromptOverride: """
                    You are a macOS/Swift development assistant. Help with Xcode projects, \
                    Swift code, git workflows, terminal commands, and debugging. Be concise \
                    and code-focused. Prefer showing code over explaining concepts. Use \
                    fenced code blocks with language tags.
                    """,
                allowedToolIDs: [
                    "run_shell_command", "open_terminal", "open_terminal_with_command",
                    "read_file", "write_file", "edit_file", "append_to_file",
                    "list_directory", "find_files", "search_file_contents",
                    "directory_tree", "file_preview", "read_pdf_text",
                    "open_file", "open_file_with_app", "reveal_in_finder",
                    "get_clipboard_text", "set_clipboard_text",
                    "search_web", "fetch_url_content", "instant_search",
                    "browser_task", "browser_extract",
                    "show_notification", "speak_text",
                    "save_memory", "recall_memories",
                    "request_tools"
                ],
                memoryNamespace: "dev",
                modelOverride: nil,
                maxTokenBudget: nil,
                color: "#2196F3",
                icon: "chevron.left.forwardslash.chevron.right",
                isBuiltIn: true,
                keywords: [
                    "code", "git", "npm", "pip", "brew", "compile", "debug",
                    "deploy", "refactor", "function", "class", "API", "docker",
                    "database", "SQL", "Swift", "Python", "JavaScript", "TypeScript",
                    "Xcode", "build", "test", "commit", "push", "pull", "merge",
                    "branch", "lint", "format", "error", "bug", "fix", "crash",
                    "stack trace", "exception", "dependency", "package", "module",
                    "import", "export", "variable", "method", "struct", "enum",
                    "protocol", "interface", "server", "endpoint", "REST", "GraphQL"
                ]
            )

        case "daily":
            return AgentProfile(
                id: "daily",
                displayName: "Daily Life",
                systemPromptOverride: """
                    You are a personal productivity assistant. Help with scheduling, messaging, \
                    reminders, weather, news, and daily planning. Be warm but efficient. \
                    Understand both English and Chinese commands. When returning dates or events, \
                    include the ISO 8601 date for calendar integration. When returning news, \
                    format as headline blocks.
                    """,
                allowedToolIDs: [
                    "send_message", "send_wechat_message", "send_imessage",
                    "send_whatsapp_message", "fetch_wechat_messages", "read_messages",
                    "wechat_sent_history",
                    "create_calendar_event", "query_calendar_events",
                    "create_reminder", "query_reminders",
                    "set_timer", "schedule_task", "list_scheduled_tasks",
                    "get_weather",
                    "fetch_news",
                    "show_notification", "speak_text",
                    "get_clipboard_text", "set_clipboard_text",
                    "search_web", "instant_search",
                    "save_memory", "recall_memories",
                    "request_tools"
                ],
                memoryNamespace: "daily",
                modelOverride: nil,
                maxTokenBudget: nil,
                color: "#FF9800",
                icon: "sun.max.fill",
                isBuiltIn: true,
                keywords: [
                    "reminder", "calendar", "meeting", "weather", "timer", "alarm",
                    "schedule", "grocery", "workout", "email", "errands", "todo",
                    "appointment", "birthday", "event", "deadline", "morning",
                    "afternoon", "evening", "tonight", "tomorrow", "weekend",
                    "message", "text", "call", "tell", "ask", "reply",
                    "news", "headlines", "briefing", "daily", "plan",
                    "lunch", "dinner", "breakfast", "commute", "travel",
                    "mom", "dad", "妈", "爸", "给", "发消息", "提醒", "天气",
                    "日程", "日历", "闹钟", "新闻"
                ]
            )

        case "coworking":
            return AgentProfile(
                id: "coworking",
                displayName: "Coworker",
                systemPromptOverride: """
                    You are a proactive coworking assistant. The user is actively working and you \
                    are observing their activity to offer contextual help at natural pause moments.

                    RULES:
                    - Be extremely concise. One sentence per suggestion.
                    - Never repeat a suggestion the user dismissed.
                    - Phrase suggestions as questions: "Want me to..." not "I will..."
                    - If the user accepts, execute efficiently with minimal tool calls.
                    - Respect focus mode — in Work mode, only suggest high-value items.
                    - Never suggest anything during presentations or screen sharing.
                    """,
                allowedToolIDs: [
                    "recall_memories", "save_memory",
                    "query_calendar_events", "create_reminder", "query_reminders",
                    "read_file", "list_directory", "find_files",
                    "open_file", "reveal_in_finder",
                    "get_clipboard_text", "set_clipboard_text",
                    "fetch_url_content", "instant_search",
                    "show_notification",
                    "request_tools"
                ],
                memoryNamespace: "coworking",
                modelOverride: nil,
                maxTokenBudget: 500,
                color: "#FFB347",
                icon: "person.2.fill",
                isBuiltIn: true,
                keywords: []  // Not command-routed — this is a proactive-only agent
            )

        default:
            return nil
        }
    }
}
