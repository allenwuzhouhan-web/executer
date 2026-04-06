import Foundation

// MARK: - Tool Usage Guide Models

struct UsageExample: Codable {
    let userRequest: String
    let toolChain: [String]  // tool names in order
    let explanation: String
}

struct ToolUsageGuide: Codable {
    let toolName: String
    let category: String
    let whenToUse: String
    let composesWellWith: [String]
    let examples: [UsageExample]
    let commonMistakes: [String]
}

// MARK: - Tool Catalog Manager

/// Manages tool usage guides — teaches the LLM how to compose tools for complex tasks.
/// Guides are filtered by query intent and injected into the system prompt.
final class ToolCatalogManager {
    static let shared = ToolCatalogManager()

    private(set) var guides: [ToolUsageGuide] = []
    private var guidesByCategory: [String: [ToolUsageGuide]] = [:]

    private init() {
        guides = Self.builtInGuides
        for guide in guides {
            guidesByCategory[guide.category, default: []].append(guide)
        }
        print("[ToolCatalog] Loaded \(guides.count) tool guides")
    }

    // MARK: - Prompt Section

    /// Returns a formatted prompt section with relevant tool composition patterns.
    /// Budget: 2000-3000 chars. Provider-aware: DeepSeek gets more examples.
    func promptSection(categories: Set<ToolCategory>, provider: LLMProvider) -> String {
        let relevant = guides.filter { guide in
            categories.contains(where: { $0.rawValue == guide.category }) ||
            guide.category == "general"
        }

        guard !relevant.isEmpty else { return "" }

        let isWeakerModel = provider == .deepseek || provider == .kimi || provider == .minimax
        let maxGuides = isWeakerModel ? 8 : 4
        let maxExamples = isWeakerModel ? 2 : 1

        var lines = ["\n\n## Tool Composition Guide", ""]

        for guide in relevant.prefix(maxGuides) {
            lines.append("**\(guide.toolName)**: \(guide.whenToUse)")
            if !guide.composesWellWith.isEmpty {
                lines.append("  Chains with: \(guide.composesWellWith.joined(separator: " → "))")
            }
            for example in guide.examples.prefix(maxExamples) {
                lines.append("  Example: \"\(example.userRequest)\" → \(example.toolChain.joined(separator: " → "))")
            }
            if let firstMistake = guide.commonMistakes.first, isWeakerModel {
                lines.append("  Avoid: \(firstMistake)")
            }
        }

        var result = lines.joined(separator: "\n")
        // Hard cap at 3000 chars for guides
        if result.count > 3000 {
            result = String(result.prefix(2950)) + "\n..."
        }

        // Append keyboard shortcuts reference when keyboard tools are active
        if categories.contains(.keyboard) {
            result += Self.keyboardShortcutsReference
        }

        return result
    }

    // MARK: - Keyboard Shortcuts Reference (injected on-demand)

    /// Full macOS keyboard shortcuts reference — only included when keyboard category is active.
    /// This saves ~1500 tokens on every non-UI API call.
    private static let keyboardShortcutsReference = """

    ## macOS Keyboard Shortcuts (use with `hotkey` tool)

    Common: cut "cmd+x" | copy "cmd+c" | paste "cmd+v" | undo "cmd+z" | redo "cmd+shift+z" | select all "cmd+a" | find "cmd+f" | find next "cmd+g" | save "cmd+s" | save as "cmd+shift+s" | print "cmd+p" | open "cmd+o" | new tab "cmd+t" | close window "cmd+w" | close all "cmd+alt+w" | minimize "cmd+m" | hide app "cmd+h" | hide others "cmd+alt+h" | quit "cmd+q" | force quit "cmd+alt+escape" | spotlight "cmd+space" | emoji "ctrl+cmd+space" | full screen "ctrl+cmd+f" | switch apps "cmd+tab" | switch windows "cmd+`" | screenshot tools "cmd+shift+5" | screenshot full "cmd+shift+3" | screenshot region "cmd+shift+4" | settings "cmd+," | lock screen "ctrl+cmd+q"

    Browser: address bar "cmd+l" | new tab "cmd+t" | close tab "cmd+w" | refresh "cmd+r" | back "cmd+[" | forward "cmd+]" | reopen closed tab "cmd+shift+t" | next tab "ctrl+tab" | prev tab "ctrl+shift+tab" | zoom in "cmd+=" | zoom out "cmd+-" | reset zoom "cmd+0" | incognito "cmd+shift+n" (Chrome) / "cmd+shift+p" (Firefox)

    Text: bold "cmd+b" | italic "cmd+i" | underline "cmd+u" | delete word left alt+delete | delete char right fn+delete | line start "cmd+left" | line end "cmd+right" | doc start "cmd+up" | doc end "cmd+down" | word left "alt+left" | word right "alt+right" | select to line start "cmd+shift+left" | select to line end "cmd+shift+right" | select to doc start "cmd+shift+up" | select to doc end "cmd+shift+down" | select word left "alt+shift+left" | select word right "alt+shift+right" | page up fn+up | page down fn+down | home fn+left | end fn+right | add link "cmd+k" | paste style "cmd+alt+v" | paste plain "cmd+alt+shift+v"

    Finder: get info "cmd+i" | duplicate "cmd+d" | alias "ctrl+cmd+a" | go to folder "cmd+shift+g" | desktop "cmd+shift+d" | home "cmd+shift+h" | downloads "cmd+alt+l" | documents "cmd+shift+o" | utilities "cmd+shift+u" | iCloud "cmd+shift+i" | airdrop "cmd+shift+r" | recents "cmd+shift+f" | computer "cmd+shift+c" | icons/list/columns/gallery "cmd+1"/"cmd+2"/"cmd+3"/"cmd+4" | path bar "cmd+alt+p" | sidebar "cmd+alt+s" | status bar "cmd+/" | view options "cmd+j" | trash "cmd+delete" | empty trash "cmd+shift+delete" | move files "cmd+c" then "cmd+alt+v" | back "cmd+[" | forward "cmd+]" | parent "cmd+up" | open item "cmd+down" | toggle dock "cmd+alt+d"

    System: mission control "ctrl+up" | app exposé "ctrl+down" | show desktop fn+f11 | notification center fn+n | control center fn+c | dock fn+a | dictation fn+d | quick note fn+q | launchpad fn+shift+a | switch spaces "ctrl+left"/"ctrl+right" | new folder "cmd+shift+n"

    Accessibility: shortcuts panel "cmd+alt+f5" | invert colors "ctrl+alt+cmd+8" | focus menu bar "ctrl+f2" | focus dock "ctrl+f3" | voiceover "cmd+f5"
    """

    // MARK: - On-Demand Lookup

    func getGuide(for toolName: String) -> ToolUsageGuide? {
        return guides.first { $0.toolName == toolName }
    }

    // MARK: - Built-in Guides

    private static let builtInGuides: [ToolUsageGuide] = [
        // File Operations Chain
        ToolUsageGuide(
            toolName: "find_files → read",
            category: "files",
            whenToUse: "When the user references a file by name, project, or description — ALWAYS search first, then read.",
            composesWellWith: ["find_files", "read_file", "read_pdf_text", "read_document"],
            examples: [
                UsageExample(
                    userRequest: "summarize my Q1 report",
                    toolChain: ["find_files(name: 'Q1*', directory: '~/Documents/works')", "read_file or read_pdf_text or read_document", "summarize"],
                    explanation: "Search for the file first, pick the right reader based on extension, then summarize."
                ),
                UsageExample(
                    userRequest: "read my presentation",
                    toolChain: ["find_files(name: '*.pptx', directory: '~/Documents/works')", "read_document(format: 'structure')"],
                    explanation: "Use read_document for PPTX/DOCX/XLSX, not read_file (which fails on binary files)."
                ),
            ],
            commonMistakes: [
                "Don't use read_file on .pptx/.docx/.xlsx — use read_document instead.",
                "Don't guess file paths — always find_files first.",
            ]
        ),

        // Document Creation Chain
        ToolUsageGuide(
            toolName: "create_document",
            category: "documents",
            whenToUse: "When creating presentations (PPTX), Word docs (DOCX), or spreadsheets (XLSX). EXECUTE IMMEDIATELY — never describe slides in text or outline a plan. Generate the full spec and call the tool.",
            composesWellWith: ["search_images", "setup_python_docs", "list_document_styles", "create_presentation", "open_file"],
            examples: [
                UsageExample(
                    userRequest: "create a presentation about AI",
                    toolChain: ["search_images(query: 'artificial intelligence technology')", "create_presentation(spec: '{slides: [...]}')", "open_file"],
                    explanation: "Search images first for visuals. Generate FULL JSON spec with varied layouts (title, big_number, cards, image_right, process — NOT all content+bullets). Call create_presentation immediately — never describe slides in text."
                ),
                UsageExample(
                    userRequest: "make a word doc with meeting notes",
                    toolChain: ["create_document(format: 'docx', content: {sections: [...]})", "open_file"],
                    explanation: "Content uses sections array with headings, body text, and bullet points."
                ),
            ],
            commonMistakes: [
                "Don't use write_file for PPTX/DOCX — use create_document.",
                "If python libraries aren't installed, call setup_python_docs first.",
            ]
        ),

        // Style Learning Chain
        ToolUsageGuide(
            toolName: "extract_document_style",
            category: "documents",
            whenToUse: "When the user wants to learn/copy a document's visual style for reuse.",
            composesWellWith: ["find_files", "extract_document_style", "create_document"],
            examples: [
                UsageExample(
                    userRequest: "learn my presentation style from this deck",
                    toolChain: ["extract_document_style(path: '...', profile_name: '...')", "save_memory"],
                    explanation: "Extract the style and save a memory about the user's preference."
                ),
            ],
            commonMistakes: ["Always name the profile descriptively (e.g., 'Allen Pitch Deck' not 'style1')."]
        ),

        // Screen Reading Chain
        ToolUsageGuide(
            toolName: "capture_screen → ocr",
            category: "screenshot",
            whenToUse: "When the user asks to look at, read, or analyze what's on their screen.",
            composesWellWith: ["capture_screen", "ocr_image"],
            examples: [
                UsageExample(
                    userRequest: "what's on my screen",
                    toolChain: ["capture_screen", "ocr_image(path: screenshot_path)"],
                    explanation: "Screenshot first, then OCR to extract text, then answer."
                ),
            ],
            commonMistakes: ["Don't capture_screen between action steps to 'verify' — trust your commands."]
        ),

        // Research Chain
        ToolUsageGuide(
            toolName: "fetch_url_content (parallel)",
            category: "webContent",
            whenToUse: "When researching a topic — fetch multiple URLs in ONE response for speed.",
            composesWellWith: ["fetch_url_content", "set_clipboard_text"],
            examples: [
                UsageExample(
                    userRequest: "research quantum computing",
                    toolChain: ["fetch_url_content(url1) + fetch_url_content(url2) + fetch_url_content(url3) [PARALLEL]", "synthesize", "set_clipboard_text"],
                    explanation: "Batch all URL fetches in a single response. They run in parallel automatically."
                ),
            ],
            commonMistakes: ["Don't fetch URLs one at a time — batch them all in one response."]
        ),

        // Browser Automation (browser-use) — for complex web interactions
        ToolUsageGuide(
            toolName: "browser_task",
            category: "browser",
            whenToUse: "When interacting with web pages: filling forms, logging in, clicking buttons, navigating checkout flows, booking, shopping, scraping dynamic content. Do NOT use for simple URL reads (use fetch_url_content) or reading the current Safari page (use read_safari_page).",
            composesWellWith: ["browser_extract", "browser_session", "save_memory", "set_clipboard_text", "write_file"],
            examples: [
                UsageExample(
                    userRequest: "book a restaurant on OpenTable for Friday",
                    toolChain: ["browser_task(task: 'Go to opentable.com and book a table for 2 on Friday evening', visible: true)"],
                    explanation: "Complex multi-step web interaction — use browser_task. Set visible for tasks needing user oversight."
                ),
                UsageExample(
                    userRequest: "extract all product prices from this Amazon page",
                    toolChain: ["browser_extract(url: '...', instruction: 'Extract product names and prices')"],
                    explanation: "Data extraction from dynamic page — use browser_extract, not browser_task."
                ),
            ],
            commonMistakes: [
                "Don't use browser_task for simple page reads — use fetch_url_content instead.",
                "Don't use cursor/keyboard tools to automate web pages — use browser_task instead (it has DOM awareness).",
                "For reading the current Safari/Chrome page, use read_safari_page/read_chrome_page — no need to start a browser session.",
            ]
        ),

        // Messaging Chain
        ToolUsageGuide(
            toolName: "send_message",
            category: "messaging",
            whenToUse: "When sending messages via iMessage, WeChat, or WhatsApp.",
            composesWellWith: ["send_imessage", "send_wechat_message", "send_whatsapp_message"],
            examples: [
                UsageExample(
                    userRequest: "text John hello",
                    toolChain: ["recall_memories(query: 'John contact')", "send_imessage or send_wechat_message"],
                    explanation: "Check memories for contact platform preference, then use the right sender."
                ),
            ],
            commonMistakes: ["Always confirm before sending messages to avoid mistakes."]
        ),

        // Skill Import Chain
        ToolUsageGuide(
            toolName: "import_skill",
            category: "skills",
            whenToUse: "When importing new skills from GitHub or external sources.",
            composesWellWith: ["search_github_skills", "import_skill", "verify_skill_now", "list_pending_skills"],
            examples: [
                UsageExample(
                    userRequest: "find me some useful automation skills",
                    toolChain: ["search_github_skills(query: 'macOS automation')", "import_skill(url: '...')", "verify_skill_now or wait for overnight check"],
                    explanation: "Search GitHub, import promising skills, they go through safety verification."
                ),
            ],
            commonMistakes: ["Imported skills are pending until verified. Use verify_skill_now for immediate use."]
        ),

        // Keyboard Shortcuts — prefer hotkeys over UI clicks
        ToolUsageGuide(
            toolName: "hotkey (keyboard shortcuts)",
            category: "keyboard",
            whenToUse: "ALWAYS prefer hotkey over click_element or menu navigation when a keyboard shortcut exists. Hotkeys are instant and reliable; clicking menus is slow and brittle.",
            composesWellWith: ["hotkey", "type_text", "press_key", "launch_app", "click_element"],
            examples: [
                UsageExample(
                    userRequest: "save this document",
                    toolChain: ["hotkey(combo: 'cmd+s')"],
                    explanation: "Use Cmd+S, NOT click File → Save."
                ),
                UsageExample(
                    userRequest: "copy this text and paste it in Notes",
                    toolChain: ["hotkey(combo: 'cmd+a')", "hotkey(combo: 'cmd+c')", "launch_app(name: 'Notes')", "hotkey(combo: 'cmd+v')"],
                    explanation: "Select all, copy, switch app, paste — all via hotkeys. No clicking needed."
                ),
                UsageExample(
                    userRequest: "open google.com in a new tab",
                    toolChain: ["hotkey(combo: 'cmd+t')", "type_text(text: 'google.com')", "press_key(key: 'enter')"],
                    explanation: "New tab via Cmd+T, type URL, press Enter. Don't click the + button or address bar."
                ),
                UsageExample(
                    userRequest: "go to my Downloads folder",
                    toolChain: ["launch_app(name: 'Finder')", "hotkey(combo: 'cmd+alt+l')"],
                    explanation: "Use Finder shortcut Cmd+Opt+L to jump directly to Downloads."
                ),
                UsageExample(
                    userRequest: "take a screenshot of a region",
                    toolChain: ["hotkey(combo: 'cmd+shift+4')"],
                    explanation: "Cmd+Shift+4 for region screenshot. Don't open Screenshot app."
                ),
                UsageExample(
                    userRequest: "find something on this page",
                    toolChain: ["hotkey(combo: 'cmd+f')", "type_text(text: 'search term')"],
                    explanation: "Cmd+F opens find bar, then type the query. Don't click a search icon."
                ),
            ],
            commonMistakes: [
                "Don't click File → Save when Cmd+S works.",
                "Don't click the URL bar — use Cmd+L to focus it instantly.",
                "Don't click Edit → Copy/Paste — use Cmd+C/Cmd+V.",
                "Don't click the + button for new tab — use Cmd+T.",
                "Don't navigate Finder menus — use direct shortcuts (Cmd+Shift+D for Desktop, Cmd+Shift+H for Home, etc.).",
            ]
        ),

        // Notion — Workspace & Knowledge Management
        ToolUsageGuide(
            toolName: "notion (workspace)",
            category: "productivity",
            whenToUse: "When the user wants to create, read, update, or organize content in Notion — pages, databases, wikis, project trackers, notes. Use notion_search to find existing content, notion_read_page to read it, notion_create_page to create rich pages, and notion_query_database to pull structured data.",
            composesWellWith: ["notion_search", "notion_read_page", "notion_create_page", "notion_append_blocks", "notion_get_database", "notion_query_database", "notion_add_to_database", "notion_create_database"],
            examples: [
                UsageExample(
                    userRequest: "create a project brief in Notion",
                    toolChain: ["notion_search(query: 'Projects')", "notion_create_page(parent_id: found_page_id, title: 'Project Brief', content: '# Overview\\n...')"],
                    explanation: "Search for the parent page first, then create a rich page with markdown content. The markdown is auto-converted to Notion blocks (headings, bullets, code blocks, tables, etc.)."
                ),
                UsageExample(
                    userRequest: "add a task to my Notion task database",
                    toolChain: ["notion_search(query: 'Tasks', filter: 'database')", "notion_get_database(database_id: found_db_id)", "notion_add_to_database(database_id: ..., properties: '{\"Name\": \"...\", \"Status\": \"...\"}')"],
                    explanation: "Find the database, check its schema to know property names and types, then add the entry with the right property values."
                ),
                UsageExample(
                    userRequest: "what's in my Notion meeting notes?",
                    toolChain: ["notion_search(query: 'meeting notes')", "notion_read_page(page_id: found_page_id)"],
                    explanation: "Search to find the page, then read its full content rendered as markdown."
                ),
                UsageExample(
                    userRequest: "create a tracking database in Notion",
                    toolChain: ["notion_search(query: 'parent page')", "notion_create_database(parent_page_id: ..., title: 'Bug Tracker', properties: '{\"Name\": \"title\", \"Status\": {\"type\": \"select\", \"options\": [\"Open\", \"In Progress\", \"Closed\"]}, \"Priority\": {\"type\": \"select\", \"options\": [\"P0\", \"P1\", \"P2\"]}, \"Assignee\": \"rich_text\", \"Due\": \"date\"}')"],
                    explanation: "Find a parent page, then create a database with typed columns. Use descriptive option names."
                ),
            ],
            commonMistakes: [
                "Don't skip notion_get_database before adding entries — you need to know the exact property names and types.",
                "Don't forget to search for the parent page/database first — don't guess IDs.",
                "If Notion returns 'unauthorized', the user needs to share the page with their integration in Notion (page ... menu → Connect to).",
                "When creating rich pages, write FULL markdown content — headings, bullets, code blocks, tables. Don't just write plain text paragraphs.",
            ]
        ),

        // Media Production — Video & Audio Creation
        ToolUsageGuide(
            toolName: "create_video (media production)",
            category: "media",
            whenToUse: "When the user wants to create a video from images, clips, or text — explainers, promos, montages, slideshows, tutorials. Also use for video editing (trimming, merging, overlays).",
            composesWellWith: ["search_images", "create_video", "create_audio", "ffmpeg_edit_video", "ffmpeg_probe", "plan_video", "quick_video", "create_podcast", "download_youtube"],
            examples: [
                UsageExample(
                    userRequest: "make a 30-second promo video for my bakery",
                    toolChain: ["quick_video(topic: 'My Bakery Promo', narration: 'Welcome to Sweet Bakes...', type: 'promo')"],
                    explanation: "Use quick_video for one-shot video creation — it auto-searches images, generates scenes, adds TTS, and opens the result."
                ),
                UsageExample(
                    userRequest: "create a 5-minute explainer about quantum computing",
                    toolChain: ["quick_video(topic: 'Quantum Computing', narration: 'paragraph1\\n\\nparagraph2\\n\\n...', type: 'explainer', duration_seconds: 300)"],
                    explanation: "quick_video handles the full pipeline: each narration paragraph becomes a scene, images are auto-searched, TTS and subtitles generated."
                ),
                UsageExample(
                    userRequest: "create a podcast about AI trends",
                    toolChain: ["create_podcast(title: 'AI Trends 2025', narration: 'Full episode script...', voice: 'Daniel')"],
                    explanation: "create_podcast handles TTS + background music + ducking in one call. Auto-opens the result."
                ),
                UsageExample(
                    userRequest: "download this YouTube video",
                    toolChain: ["download_youtube(url: 'https://youtube.com/watch?v=...', format: 'best_video')"],
                    explanation: "download_youtube uses yt-dlp to download and auto-opens the result. For audio only, use format: 'mp3'."
                ),
                UsageExample(
                    userRequest: "trim the first 10 seconds off this video",
                    toolChain: ["ffmpeg_edit_video(spec: {input: path, operations: [{type: 'trim', start: 10}]})"],
                    explanation: "ffmpeg_edit_video for editing existing videos. Auto-opens result."
                ),
            ],
            commonMistakes: [
                "Use quick_video for most video creation — it auto-searches images and handles everything in one call.",
                "Use create_podcast for podcast episodes — much simpler than create_audio with manual track specs.",
                "For create_video with manual spec: use 'search_query' in scenes instead of 'source' to auto-search images.",
                "Scenes shorter than 3 seconds feel rushed — use at least 4-5 seconds per scene.",
                "Always include audio (narration or background music) — silent videos feel broken.",
            ]
        ),

        // General: Parallel Execution
        ToolUsageGuide(
            toolName: "parallel execution",
            category: "general",
            whenToUse: "When multiple independent operations can run simultaneously.",
            composesWellWith: [],
            examples: [
                UsageExample(
                    userRequest: "get weather and check calendar",
                    toolChain: ["get_weather + query_calendar_events [PARALLEL in single response]"],
                    explanation: "Independent tool calls in the same response execute in parallel automatically."
                ),
            ],
            commonMistakes: ["Don't call independent tools one at a time across multiple turns."]
        ),
    ]
}

// MARK: - Get Tool Guide Tool

/// On-demand tool guide lookup — the LLM can ask "how do I use X?" mid-conversation.
struct GetToolGuideTool: ToolDefinition {
    let name = "get_tool_guide"
    let description = "Look up how to use a specific tool or tool combination. Returns usage examples, composition patterns, and common mistakes."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Tool name or task description (e.g., 'create_document', 'read office files', 'browser automation')"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args).lowercased()

        // Search guides by tool name or keywords
        let matches = ToolCatalogManager.shared.guides.filter { guide in
            guide.toolName.lowercased().contains(query) ||
            guide.category.lowercased().contains(query) ||
            guide.whenToUse.lowercased().contains(query) ||
            guide.examples.contains { $0.userRequest.lowercased().contains(query) }
        }

        guard !matches.isEmpty else {
            return "No guide found for '\(query)'. Available guides cover: files, documents, screenshots, research, browser automation, messaging, skills."
        }

        var result = ""
        for guide in matches.prefix(3) {
            result += "**\(guide.toolName)**\n"
            result += "When to use: \(guide.whenToUse)\n"
            if !guide.composesWellWith.isEmpty {
                result += "Chain: \(guide.composesWellWith.joined(separator: " → "))\n"
            }
            for ex in guide.examples {
                result += "Example: \"\(ex.userRequest)\"\n"
                result += "  → \(ex.toolChain.joined(separator: " → "))\n"
                result += "  \(ex.explanation)\n"
            }
            if !guide.commonMistakes.isEmpty {
                result += "Avoid: \(guide.commonMistakes.joined(separator: "; "))\n"
            }
            result += "\n"
        }

        return result
    }
}

