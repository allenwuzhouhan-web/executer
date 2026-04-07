import Foundation
import AppKit

/// Stage-aware system prompt builder inspired by the human visual system.
///
/// Replaces the monolithic `fullSystemPrompt()` with progressive compression:
/// - **Fovea:** Full prompt with conditional section gating (excludes irrelevant sections)
/// - **Parafovea:** Compressed prompt for follow-up turns (top-3 memories, 1 history entry)
/// - **Macula+:** Dedicated micro-prompts, never uses the full system prompt
enum ContextCompressor {

    // MARK: - Document Query Detection

    private static let documentKeywords: Set<String> = [
        "ppt", "powerpoint", "presentation", "slide", "deck",
        "word", "docx", "document", "report", "essay", "memo", "letter",
        "excel", "xlsx", "spreadsheet", "table", "data sheet",
    ]

    private static func isDocumentQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        return documentKeywords.contains { lower.contains($0) }
    }

    // MARK: - UI Query Detection

    private static let uiCategories: Set<String> = ["cursor", "browser", "windows"]

    private static func isUIQuery(_ query: String) -> Bool {
        let categories = ToolRegistry.shared.classifyQueryIntent(query)
        return !categories.intersection([.cursor, .browser, .windows]).isEmpty
    }

    // MARK: - Build Prompt by Stage

    /// Build a system prompt compressed to the given attention stage.
    /// For Stage 1-2: returns a system prompt string.
    /// For Stage 3+: returns nil (callers should use dedicated micro-prompts).
    static func build(
        context: SystemContext,
        query: String,
        stage: AttentionStage,
        manager: LLMServiceManager
    ) -> String? {
        switch stage {
        case .fovea:
            return buildFoveal(context: context, query: query, manager: manager)
        case .parafovea:
            return buildParafoveal(context: context, query: query, manager: manager)
        case .macula, .nearPeripheral, .farPeripheral:
            return nil  // These stages use dedicated micro-prompts
        }
    }

    // MARK: - Stage 1: Fovea (Conditional Section Gating)

    /// Full-detail prompt with irrelevant sections gated out.
    /// Saves ~40% tokens on non-document, non-UI queries by excluding
    /// docStyles, trainedKnowledge, designRefinements, uiKnowledge, catalogSection.
    private static func buildFoveal(
        context: SystemContext,
        query: String,
        manager: LLMServiceManager
    ) -> String {
        let buffer = FlashAttentionUtils.ContextBuffer(estimatedSegments: 16)

        // Always include: base prompt (cached)
        let basePrompt = manager.cachedBaseSystemPrompt
        buffer.append(basePrompt)

        // Always include: personality
        let personality = PersonalityEngine.shared.systemPromptSection()
        buffer.append(personality)

        // Conditional: humor (only if enabled)
        if HumorMode.shared.isEnabled {
            buffer.append(manager.humorPromptSectionText)
        }

        // Conditional: language (only if non-English)
        let language = LanguageManager.shared.systemPromptLanguageInstruction()
        if !language.isEmpty {
            buffer.append(language)
        }

        // Conditional: app-specific learned patterns (only if non-empty)
        let captured = AppState.lastCapturedAppName
        let frontmostApp = captured.isEmpty ? (NSWorkspace.shared.frontmostApplication?.localizedName ?? "") : captured
        let learned = LearningContextProvider.fullContextSection(forApp: frontmostApp, query: query)
        if !learned.isEmpty {
            buffer.append("\n\n\(learned)")
        }

        // Conditional: UI knowledge (only for UI queries)
        if isUIQuery(query) {
            if let uiKnowledge = LearningDatabase.shared.formatUIKnowledgePrompt(forApp: frontmostApp) {
                buffer.append("\n\n\(uiKnowledge)")
            }

            // Tool catalog (only for UI/complex tool composition)
            let categories = ToolRegistry.shared.classifyQueryIntent(query)
            let catalog = ToolCatalogManager.shared.promptSection(categories: categories, provider: manager.currentProvider)
            if !catalog.isEmpty {
                buffer.append(catalog)
            }
        }

        // Conditional: document sections (only for document queries)
        if isDocumentQuery(query) {
            let docStyles = DocumentStyleManager.shared.promptSection()
            if !docStyles.isEmpty { buffer.append(docStyles) }

            let trainedKnowledge = DocumentStudyStore.shared.promptSection(for: query)
            if !trainedKnowledge.isEmpty { buffer.append(trainedKnowledge) }

            let designRefinements = DesignRefinementStore.shared.promptSection()
            if !designRefinements.isEmpty { buffer.append(designRefinements) }
        }

        // Always include: skills (query-filtered)
        let skills = SkillsManager.shared.filteredPromptSection(for: query)
        if !skills.isEmpty { buffer.append(skills) }

        // Always include: memory (query-filtered, excluding dormant)
        let dormantIDs = DormantContextManager.shared.dormantMemoryIDs
        let memory = MemoryManager.shared.promptSection(query: query, excludingIDs: dormantIDs)
        if !memory.isEmpty { buffer.append(memory) }

        // Always include: goals (excluding dormant)
        let goals = GoalStack.promptSection
        if !goals.isEmpty { buffer.append(goals) }

        // Always include: recent history
        buffer.append(manager.recentHistorySection())

        // Always include: context addendum
        buffer.append("\n\n\(context.systemPromptAddendum)")

        // Always include: format guide
        buffer.append(Self.formatGuide)

        let result = buffer.build()
        let estimatedTokens = result.count / 4
        print("[Foveal] Stage 1 prompt: ~\(estimatedTokens) tokens (gated: doc=\(isDocumentQuery(query)), ui=\(isUIQuery(query)))")
        return result
    }

    // MARK: - Stage 2: Parafovea (Aggressive Compression)

    /// Compressed prompt for follow-up turns. Drops all non-essential sections
    /// since they were already loaded in the foveal turn.
    private static func buildParafoveal(
        context: SystemContext,
        query: String,
        manager: LLMServiceManager
    ) -> String {
        let buffer = FlashAttentionUtils.ContextBuffer(estimatedSegments: 8)

        // Base prompt (same as foveal, cached)
        buffer.append(manager.cachedBaseSystemPrompt)

        // Personality: compressed to 1 sentence
        buffer.append("\nYou are Executer, a macOS AI assistant. Continue the conversation.")

        // Memory: top 3 only
        let dormantIDs = DormantContextManager.shared.dormantMemoryIDs
        let memory = MemoryManager.shared.promptSection(query: query, excludingIDs: dormantIDs, limit: 3)
        if !memory.isEmpty { buffer.append(memory) }

        // Goals: titles only
        let goals = GoalStack.promptSectionCompact
        if !goals.isEmpty { buffer.append(goals) }

        // Context addendum (system state — date, app, etc.)
        buffer.append("\n\n\(context.systemPromptAddendum)")

        let result = buffer.build()
        let estimatedTokens = result.count / 4
        print("[Parafoveal] Stage 2 prompt: ~\(estimatedTokens) tokens")
        return result
    }

    // MARK: - Stage 3: Macula Micro-Prompts

    /// Minimal prompt for coworking evaluation.
    static func maculaCoworkingPrompt(state: String, goals: String) -> String {
        """
        You are a coworking assistant. Evaluate whether to suggest something helpful.
        USER STATE: \(state)
        GOALS: \(goals.isEmpty ? "None" : goals)
        Respond with one line of JSON: {"suggest":false} or {"suggest":true,"headline":"...","type":"...","confidence":0.7}
        """
    }

    /// Minimal prompt for security risk assessment.
    static func maculaSecurityPrompt(toolName: String, args: String) -> String {
        "Classify risk of calling \(toolName) with args: \(args.prefix(300)). Reply: SAFE, CAUTION, or DANGEROUS."
    }

    // MARK: - Constants

    private static let formatGuide = """

        ## Response Formatting
        When your response includes dates, events, or news, use structured markers so the UI can render rich cards:
        - For events with a specific date: [EVENT: title | ISO-8601-date | optional-location]
        - For news summaries: [HEADLINE: title | source | one-sentence-summary | optional-url]
        - For dates/deadlines: include the full date so the user can add it to their calendar.
        - For ordered information: use numbered markdown lists.
        - For code: use fenced code blocks with language tags.
        Keep markers inline with your response text.
        """

    // MARK: - Message History Compression (Parafovea)

    /// Compress message history for Stage 2: keep last N messages,
    /// summarize older assistant responses to 1 line each.
    static func compressHistory(_ messages: [ChatMessage], maxMessages: Int) -> [ChatMessage] {
        guard messages.count > maxMessages else { return messages }

        // Always keep the system message (first)
        let systemMessage = messages.first(where: { $0.role == "system" })
        let nonSystem = messages.filter { $0.role != "system" }

        // Keep last N non-system messages at full resolution
        let recentCount = min(maxMessages, nonSystem.count)
        let recent = Array(nonSystem.suffix(recentCount))

        // Summarize older messages
        let older = nonSystem.dropLast(recentCount)
        var compressed: [ChatMessage] = []
        if let sys = systemMessage {
            compressed.append(sys)
        }

        for msg in older {
            if msg.role == "assistant", let content = msg.content, content.count > 200 {
                // Compress long assistant responses to first 150 chars
                let summary = String(content.prefix(150)) + "..."
                compressed.append(ChatMessage(role: msg.role, content: summary, tool_calls: msg.tool_calls, tool_call_id: msg.tool_call_id, reasoning_content: nil))
            } else if msg.role == "tool", let content = msg.content, content.count > 300 {
                // Compress tool results to 200 chars
                let summary = String(content.prefix(200)) + " [truncated]"
                compressed.append(ChatMessage(role: msg.role, content: summary, tool_calls: nil, tool_call_id: msg.tool_call_id, reasoning_content: nil))
            } else {
                compressed.append(msg)
            }
        }

        compressed.append(contentsOf: recent)
        return compressed
    }
}
