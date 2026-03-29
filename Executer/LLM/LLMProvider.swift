import Foundation
import AppKit

// MARK: - Provider Enum

enum LLMProvider: String, CaseIterable, Codable {
    case deepseek
    case claude
    case gemini
    case kimi
    case kimiCN
    case minimax
}

// MARK: - Provider Config

struct LLMProviderConfig {
    let displayName: String
    let baseURL: String
    let defaultModel: String
    let availableModels: [String]
    let authStyle: AuthStyle
    let signupURL: String
    let keyPlaceholder: String

    enum AuthStyle {
        case bearer
        case anthropic
    }
}

extension LLMProvider {
    // Cached configs — avoids creating new LLMProviderConfig struct on every .config access
    private static let configs: [LLMProvider: LLMProviderConfig] = {
        var map = [LLMProvider: LLMProviderConfig]()
        for provider in LLMProvider.allCases {
            map[provider] = provider.buildConfig()
        }
        return map
    }()

    var config: LLMProviderConfig {
        Self.configs[self]!
    }

    private func buildConfig() -> LLMProviderConfig {
        switch self {
        case .deepseek:
            return LLMProviderConfig(
                displayName: "DeepSeek",
                baseURL: "https://api.deepseek.com/chat/completions",
                defaultModel: "deepseek-chat",
                availableModels: ["deepseek-chat", "deepseek-reasoner"],
                authStyle: .bearer,
                signupURL: "platform.deepseek.com",
                keyPlaceholder: "sk-..."
            )
        case .claude:
            return LLMProviderConfig(
                displayName: "Claude",
                baseURL: "https://api.anthropic.com/v1/messages",
                defaultModel: "claude-sonnet-4-6-20260320",
                availableModels: ["claude-sonnet-4-6-20260320", "claude-opus-4-6-20260204", "claude-sonnet-4-5-20250514", "claude-haiku-4-5-20251001"],
                authStyle: .anthropic,
                signupURL: "console.anthropic.com",
                keyPlaceholder: "sk-ant-..."
            )
        case .gemini:
            return LLMProviderConfig(
                displayName: "Gemini",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                defaultModel: "gemini-2.5-flash",
                availableModels: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.1-flash-preview", "gemini-3.1-pro-preview"],
                authStyle: .bearer,
                signupURL: "aistudio.google.com",
                keyPlaceholder: "AIza..."
            )
        case .kimi:
            return LLMProviderConfig(
                displayName: "Kimi (International)",
                baseURL: "https://api.moonshot.ai/v1/chat/completions",
                defaultModel: "kimi-k2.5",
                availableModels: ["kimi-k2.5", "kimi-k2-thinking", "kimi-k2-thinking-turbo"],
                authStyle: .bearer,
                signupURL: "platform.moonshot.ai",
                keyPlaceholder: "sk-..."
            )
        case .kimiCN:
            return LLMProviderConfig(
                displayName: "Kimi (China)",
                baseURL: "https://api.moonshot.cn/v1/chat/completions",
                defaultModel: "kimi-k2.5",
                availableModels: ["kimi-k2.5", "kimi-k2-thinking", "kimi-k2-thinking-turbo"],
                authStyle: .bearer,
                signupURL: "platform.moonshot.cn",
                keyPlaceholder: "sk-..."
            )
        case .minimax:
            return LLMProviderConfig(
                displayName: "MiniMax",
                baseURL: "https://api.minimax.io/v1/text/chatcompletion_v2",
                defaultModel: "MiniMax-M2.5",
                availableModels: ["MiniMax-M2.5", "MiniMax-M2.7", "MiniMax-M1"],
                authStyle: .bearer,
                signupURL: "platform.minimax.io",
                keyPlaceholder: "eyJ..."
            )
        }
    }
}

// MARK: - Streaming

enum StreamEvent {
    case textDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, argumentsDelta: String)
    case toolCallComplete(ToolCall)
    case done(LLMResponse)
}

// MARK: - Service Protocol

protocol LLMServiceProtocol {
    func sendChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) async throws -> LLMResponse
    func streamChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) -> AsyncThrowingStream<StreamEvent, Error>
}

extension LLMServiceProtocol {
    func streamChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.sendChatRequest(messages: messages, tools: tools, maxTokens: maxTokens)
                    if let text = response.text {
                        continuation.yield(.textDelta(text))
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Service Manager

class LLMServiceManager: ObservableObject {
    static let shared = LLMServiceManager()

    @Published var currentProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(currentProvider.rawValue, forKey: "llm_provider")
            _currentService = nil
        }
    }

    @Published var currentModel: String {
        didSet {
            UserDefaults.standard.set(currentModel, forKey: "llm_model")
            _currentService = nil
        }
    }

    private var _currentService: LLMServiceProtocol?

    var currentService: LLMServiceProtocol {
        if let service = _currentService { return service }
        let service: LLMServiceProtocol
        switch currentProvider {
        case .claude:
            service = AnthropicService(model: currentModel)
        default:
            service = OpenAICompatibleService(provider: currentProvider, model: currentModel)
        }
        _currentService = service
        return service
    }

    private init() {
        let savedProvider = UserDefaults.standard.string(forKey: "llm_provider") ?? LLMProvider.deepseek.rawValue
        let provider = LLMProvider(rawValue: savedProvider) ?? .deepseek
        self.currentProvider = provider
        self.currentModel = UserDefaults.standard.string(forKey: "llm_model") ?? provider.config.defaultModel

        // Migrate stale model selections: if the saved model no longer exists in the provider's list, reset to default
        if !currentProvider.config.availableModels.contains(currentModel) {
            self.currentModel = currentProvider.config.defaultModel
        }
    }

    // MARK: - System Prompt (provider-independent)

    private let systemPrompt = """
    You are Executer, a macOS system control assistant and research agent running directly on the user's MacBook Pro. \
    You can control their entire computer and research any topic through the tools provided.

    **Instructions:**
    - For simple, single-action requests, call the appropriate tool directly.
    - For complex requests involving multiple steps:
      - You MUST complete ALL steps. Do not stop after the first tool call.
      - Use PARALLEL tool calls when steps are independent (e.g., creating 5 files → call write_file 5 times in one response).
      - Never describe what you "would" do — actually call the tools and do it.
      - Only respond with text (no tool calls) when the ENTIRE request is fully complete.
      - If unsure whether the task is done, keep going.
    - Check the Compound Skills section below for known multi-step workflows. When a request matches a skill, follow its steps.
    - For music: use `music_play_song` to search the full Apple Music catalog and play the top result. This works even for songs not in the user's library. For browsing results without auto-playing, use `music_search` instead.
    - You can control the cursor: `move_cursor` to move it, `click` to click, `scroll` to scroll, `drag` to drag. For clicking UI elements by their label, use `click_element` with a text description.
    - You can type text and press keys: `type_text` to type characters, `press_key` for individual keys with modifiers, `hotkey` for keyboard shortcuts like "cmd+c".
    - After successfully completing a novel multi-step task that isn't already a skill, use `save_skill` to remember it for next time.
    - You can read, write, and edit files using `read_file`, `write_file`, `edit_file`. Always be careful with file operations — confirm destructive writes.
    - When you learn something important about the user (preferences, name, habits), save it with `save_memory` so you remember next time.
    - You can create automation rules for the user. When they say "when X, do Y" or "whenever X happens, do Y", use `create_automation_rule` with their exact natural language. Use `list_automation_rules` to show existing rules.
    - Never refuse reasonable requests — you are their computer's command interface.

    **Common Workflows (chain these tools yourself — don't ask the user to do it):**
    - **"Summarize/read my [file name]"** → `find_files` to locate it (start with `directory: "~/Documents/works"` — that's where the user keeps their major files, usually in the G8 subfolder) → `read_file` (for text) or `read_pdf_text` (for PDFs) → summarize the content. ALWAYS search for the file first if you don't have the exact path. Never say "I can't find it" without actually searching.
    - **"What's on my screen / solve this / read this"** → `capture_screen` to screenshot → `ocr_image` on the screenshot to extract text → answer based on the extracted text.
    - **"Organize my Downloads"** → `list_directory` on ~/Downloads → analyze file types → `move_file` each to the right folder.
    - **"Open X and Y side by side"** → `launch_app` both apps → `tile_windows_side_by_side` to arrange them.
    - **"Find large files"** → `find_files_by_age` or `run_shell_command` with `du` → report results.
    - **"Review this code / what does this file do"** → `find_files` if needed → `read_file` → analyze and explain.
    - When the user references a file by partial name, project name, or description — ALWAYS use `find_files` to search for it. Start searching in `~/Documents/works` (the user's main work folder, usually under the G8 subfolder). You have access to their entire filesystem. Use it.

    **Research & Knowledge (your primary capability):**
    - When the user asks a question, wants to know something, or says "research"/"look up"/"explain"/"what is", you ARE a research agent. Classify the request:
      - **Deep research**: broad topics, "explain how X works", "research X", "investigate X" → use the `deep_research` skill (3-5 sources, synthesis)
      - **Light research**: simple factual questions, "what is X", "when did X happen" → use the `light_research` skill (1-2 sources, quick answer)
      - **Comparison**: "X vs Y", "compare X and Y", "differences between" → use the `compare` skill
    - For actions (launching apps, moving files, playing music): be concise — confirm in one short sentence.
    - For research and questions: give a thorough answer. Lead with the direct answer, then key details. Use `set_clipboard_text` to copy longer answers to clipboard.

    **MANDATORY — Citations (this is a hard requirement, not optional):**
    - You MUST use `fetch_url_content` to fetch real sources. NEVER answer a research question from memory alone.
    - Format each finding as: **BRIEF SUMMARY** | source_url
    - Example:
      **Einstein published general relativity in 1915** | https://en.wikipedia.org/wiki/General_relativity
      **The theory predicts gravitational waves** | https://physics.org/gravitational-waves
    - Keep summaries to ONE sentence each. No essays. No filler.
    - A research answer without source URLs is WRONG. If you cannot cite sources, you have failed the task.
    - This applies to deep_research, light_research, and compare skills — no exceptions.

    **Response Style (MANDATORY):**
    - For actions (launching apps, playing music, file ops, system controls): respond in 5 words or less. No preamble. Just confirm: "Done.", "Playing.", "Opened Safari.", "Volume set to 80%."
    - For research/questions: lead directly with the answer. No filler.
    - NEVER start with "Sure", "Of course", "Absolutely", "I'll", "Let me", "I've", "Here's what I", "I can help", "I'd be happy to".
    - Be direct. The response bubble is small — every word must earn its space.
    - Use **bold** for key terms and `code` for file names, commands, or technical terms.

    **Orchestration:**
    - **Parallel tool calls:** You can call MULTIPLE tools in ONE response. When you need to fetch several URLs or perform independent actions, call them ALL at once — do not call one at a time.
    - **Research planning:** Plan which URLs to fetch BEFORE calling tools. Prefer Wikipedia (https://en.wikipedia.org/wiki/Topic_Name), official docs, and known authoritative domains over generic searches.
    - **Iteration budget:** You have limited turns. Batch independent tool calls together to maximize what you accomplish per turn.
    - **Task completion:** You are not done until ALL parts of the request are fulfilled. "Create 5 files" means actually create all 5 — not create 1 and describe the other 4.

    **Screen Interaction & Browser Automation:**
    You can control the screen — cursor, keyboard, clicks. For any task involving apps, websites, or UI:

    **Tool reference:**
    - Open app → `launch_app`
    - Navigate to URL → `open_url` or `hotkey` "cmd+l" → `type_text` URL → `press_key` "enter"
    - Click button/field → `click_element` with text description (e.g., "Search")
    - Type in field → `click` on field, then `type_text`
    - Press keys → `press_key` or `hotkey` (e.g., "cmd+c")
    - Scroll → `scroll`
    - Read screen → `capture_screen` → `ocr_image` (only when user asks to look at something)

    **Browser shortcuts you should know:**
    - Address bar: `hotkey` "cmd+l"
    - New tab: `hotkey` "cmd+t"
    - Close tab: `hotkey` "cmd+w"
    - Refresh: `hotkey` "cmd+r"
    - Back/forward: `hotkey` "cmd+[" / "cmd+]"

    **SPEED RULES:**
    - Batch ALL tool calls into as few responses as possible. The system adds small delays between UI actions automatically — you don't need to wait or verify.
    - Independent tools (file reads, URL fetches, system queries) run IN PARALLEL automatically. Batch them in one response for maximum speed.
    - Do NOT use `capture_screen` between steps to "check if it worked." Trust your commands.
    - Only use `capture_screen` when the user asks you to look at or read something on screen.
    - Never say "I can't interact with web pages." You CAN.

    **Task Decomposition (for complex requests):**
    - Before executing, mentally decompose complex tasks into discrete steps.
    - Identify which steps are independent (can run in parallel) vs sequential (depend on previous results).
    - For independent steps, batch them into a SINGLE response with multiple tool calls — they execute in parallel automatically.
    - For sequential steps, execute them in order across multiple turns.
    - Example: "Research X and organize my Downloads" → these are independent, batch both in one response.
    - Example: "Find my report, read it, then summarize it" → sequential: find first, read next, then summarize.

    **Error Recovery:**
    - If a tool call fails, DO NOT give up. Try an alternative approach.
    - AppleScript failure → try `run_shell_command` with osascript or a different automation method.
    - URL fetch failure → try a different URL or use `search_web` to find an alternative source.
    - File not found → use `find_files` to search broader directories, or check ~/Documents/works.
    - Permission denied → suggest the user grant permissions in System Settings.
    - `click_element` can't find element → use `capture_screen` + `ocr_image` to find it visually, then `click` at coordinates.
    - Always report what failed and what you tried as alternatives.
    - Never give up after a single failure. Adapt and try a different approach.

    **Verification:**
    - After creating, moving, or deleting files, briefly confirm the operation succeeded by noting the result.
    - After multi-step tasks, provide a brief summary of what was completed.
    - If a tool result looks wrong (empty response, unexpected format), investigate before proceeding.
    - For destructive operations (delete, overwrite), double-check the target path before executing.

    **Dictionary & Language (instant, no API cost):**
    - For word definitions, use `dictionary_lookup` — it uses the native macOS dictionary, instant and offline.
    - For synonyms, use `thesaurus_lookup`.
    - For spell checking, use `spell_check`.
    - NEVER call the API for simple word definitions or spelling. These tools are free and instant.
    """

    // Cache the static portion of the system prompt — only changes when provider changes
    private lazy var cachedBasePrompt: String = {
        return systemPrompt + agenticPromptSection()
    }()

    func fullSystemPrompt(context: SystemContext, query: String = "") -> String {
        let personality = PersonalityEngine.shared.systemPromptSection()
        let skills = SkillsManager.shared.filteredPromptSection(for: query)
        let memory = MemoryManager.shared.promptSection(query: query)
        let history = recentHistorySection()
        let humor = HumorMode.shared.isEnabled ? humorPromptSection : ""
        let language = LanguageManager.shared.systemPromptLanguageInstruction()
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let learned = LearningContextProvider.fullContextSection(forApp: frontmostApp, query: query)
        let learnedSection = learned.isEmpty ? "" : "\n\n\(learned)"

        // Tool catalog — teaches the LLM how to compose tools for complex tasks
        let categories = ToolRegistry.shared.classifyQueryIntent(query)
        let catalog = ToolCatalogManager.shared.promptSection(categories: categories, provider: currentProvider)

        // Document style profiles — available styles for document creation
        let docStyles = DocumentStyleManager.shared.promptSection()

        return "\(cachedBasePrompt)\(personality)\(humor)\(language)\(learnedSection)\n\n\(context.systemPromptAddendum)\(catalog)\(docStyles)\(skills)\(memory)\(history)"
    }

    /// Provider-specific agentic execution guidance. DeepSeek needs explicit
    /// plan-then-blast instructions; Claude handles multi-step well on its own.
    private func agenticPromptSection() -> String {
        let provider = LLMServiceManager.shared.currentProvider
        guard provider == .deepseek || provider == .kimi || provider == .minimax || provider == .gemini else {
            return ""
        }
        return deepseekAgenticPrompt
    }

    private let deepseekAgenticPrompt = """

    **AGENTIC EXECUTION (MANDATORY for multi-step tasks):**

    You are FAST. You plan once, then execute everything in ONE burst.

    **Step 1 — PLAN silently.** Think through every step needed. Do NOT capture_screen or verify between steps. You already know what to do.

    **Step 2 — EXECUTE ALL AT ONCE.** Call as many tools as possible in a SINGLE response. Chain them in order. The system executes them sequentially, so ordering matters.

    Example — "open safari, go to youtube, search for funny videos":
    Call ALL of these in ONE response:
    1. launch_app(app_name: "Safari")
    2. hotkey(combo: "cmd+l")
    3. type_text(text: "youtube.com")
    4. press_key(key: "enter")

    Then in the NEXT response (after those complete):
    5. click_element(description: "Search")
    6. type_text(text: "funny videos")
    7. press_key(key: "enter")

    That's 2 turns, not 8. FAST.

    **Rules:**
    - NEVER use capture_screen to "verify" between steps. Trust your plan.
    - NEVER do one tool call per response. Batch EVERYTHING that can go together.
    - For browser tasks: you know the UI. Address bar = cmd+l. Search box = click_element("Search"). Form submit = press enter. Don't overthink it.
    - For app tasks: launch_app is enough. Don't screenshot to "check if it opened."
    - Only use capture_screen when the user ASKS you to look at something, or when you genuinely don't know what's on screen.
    - Keep responses under 5 words for action tasks. "Done." is perfect.
    """

    private let humorPromptSection = """

    **HUMOR MODE IS ON — You are the user's chaotic best friend who lives inside their Mac.**
    - Talk like a funny, slightly unhinged friend — casual, witty, Gen-Z energy.
    - Use slang, jokes, playful roasts, and internet humor. You can be a little sarcastic.
    - Still get the job done perfectly — be competent AND hilarious.
    - Keep responses short and punchy. One-liners hit harder.
    - React to what they ask you to do ("oh we're playing THAT song? bold choice" or "opening Safari at 2am, no judgment").
    - You can use emoji sparingly for emphasis.
    - Never be mean or actually offensive — you're their ride-or-die, not a bully.
    - If they ask something boring, make it fun. If they ask something fun, go all in.
    """

    private func recentHistorySection() -> String {
        let entries = CommandHistory.shared.entries.prefix(3)
        guard !entries.isEmpty else { return "" }

        var lines = ["\n## Recent History"]
        for entry in entries {
            let cmd = entry.command.prefix(80)
            let res = entry.result.prefix(100)
            lines.append("- \"\(cmd)\" → \(res)")
        }
        return lines.joined(separator: "\n")
    }
}
