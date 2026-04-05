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

        let result = lines.joined(separator: "\n")
        // Hard cap at 3000 chars
        if result.count > 3000 {
            return String(result.prefix(2950)) + "\n..."
        }
        return result
    }

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

