import SwiftUI

class AppState: ObservableObject {
    @Published var inputBarVisible = false
    @Published var inputBarState: InputBarState = .idle
    @Published var currentInput = ""
    @Published var lastSubmittedPrompt = ""
    @Published var resultText = ""
    @Published var showHistory = false
    @Published var contextualNudge: String? = nil
    @Published var attachedFiles: [AttachedFile] = []
    @Published var voiceActive = false
    @Published var currentAgent: AgentProfile = .general

    private var currentTask: Task<Void, Never>?
    private var conversationMessages: [ChatMessage] = []
    private var lastCommandTime: Date = .distantPast

    private var inputBarPanel: InputBarPanel?
    private var notchWindow: NotchWindow?
    private var notchDetector: NotchDetector?
    private var lastToggleTime: Date = .distantPast

    private let hotkeyManager = HotkeyManager()
    private let voiceIntegration = VoiceIntegration()
    private let agentLoop = AgentLoop()

    func setup() {
        print("[AppState] setup() called")
        inputBarPanel = InputBarPanel(appState: self)
        print("[AppState] InputBarPanel created")

        // Create and show the notch overlay window (for hover magnification)
        notchWindow = NotchWindow { [weak self] in
            DispatchQueue.main.async {
                self?.toggleInputBar()
            }
        }
        notchWindow?.onFileDrop = { [weak self] urls in
            // Open bar immediately, read files in background
            DispatchQueue.main.async {
                if self?.inputBarVisible == false {
                    self?.showInputBar()
                }
            }
            // Read file contents off the main thread
            Task.detached {
                for url in urls {
                    if let file = AttachedFile.from(url: url) {
                        await MainActor.run {
                            if self?.attachedFiles.contains(where: { $0.url == url }) == false {
                                self?.attachedFiles.append(file)
                            }
                        }
                    }
                }
            }
        }
        notchWindow?.orderFrontRegardless()
        print("[AppState] NotchWindow created and shown")

        notchDetector = NotchDetector { [weak self] in
            DispatchQueue.main.async {
                print("[AppState] Notch click callback fired!")
                self?.toggleInputBar()
            }
        }
        notchDetector?.start()

        hotkeyManager.register(
            onToggle: { [weak self] in self?.toggleInputBar() },
            onVoice: { [weak self] in self?.activateVoice() }
        )

        voiceIntegration.delegate = self
        voiceIntegration.setup()

        print("[AppState] setup() complete")
    }

    // MARK: - Voice

    func activateVoice() {
        voiceIntegration.activate()
    }

    func handleVoiceCancellation() {
        voiceIntegration.handleCancellation()
    }

    // MARK: - Notch

    func updateNotchZone(_ rect: CGRect) {
        print("[AppState] updateNotchZone: \(rect), detector is \(notchDetector == nil ? "nil" : "alive")")
        notchDetector?.setCustomZone(rect)
    }

    // MARK: - Input Bar Lifecycle

    func toggleInputBar() {
        // Capture frontmost app IMMEDIATELY — before any window activation steals focus.
        // This is the earliest possible point, before debounce, before showInputBar().
        if !inputBarVisible {
            let current = NSWorkspace.shared.frontmostApplication
            if current?.bundleIdentifier != "com.allenwu.executer" {
                lastFrontmostAppName = current?.localizedName ?? ""
            }
        }

        // Debounce: NotchWindow click, CGEvent tap, and global monitor can all fire
        // on the same click — ignore duplicates within 600ms.
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.6 else {
            print("[AppState] toggleInputBar debounced")
            return
        }
        lastToggleTime = now

        print("[AppState] toggleInputBar called, currently visible: \(inputBarVisible)")

        // If voice is active, cancel the voice session
        if voiceActive {
            handleVoiceCancellation()
            return
        }

        if inputBarVisible {
            // Don't close the bar if the user is actively typing or a command is running
            let isActive: Bool = {
                switch inputBarState {
                case .processing, .executing:
                    return true  // command running — don't close
                case .ready:
                    return !currentInput.isEmpty  // user is typing — don't close
                default:
                    return false
                }
            }()
            if isActive {
                print("[AppState] toggleInputBar: bar is active, ignoring close")
                return
            }
            hideInputBar()
        } else {
            showInputBar()
        }
    }

    /// The app the user was in BEFORE opening the input bar.
    /// Captured here because once the bar opens, Executer becomes frontmost.
    var lastFrontmostAppName: String = ""

    func showInputBar() {
        guard !inputBarVisible else { return }
        // Capture frontmost app BEFORE we steal focus
        lastFrontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        print("[AppState] showInputBar() — user was in: \(lastFrontmostAppName)")
        inputBarVisible = true
        inputBarState = .ready
        currentInput = ""
        resultText = ""
        contextualNudge = nil
        inputBarPanel?.showBar()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        // Check for abandoned thoughts (async — only shows if user hasn't started typing)
        Task {
            if let recall = await ThoughtRecallService.shared.checkForAbandonedThought() {
                await MainActor.run {
                    if case .ready = self.inputBarState, self.currentInput.isEmpty {
                        self.inputBarState = .thoughtRecall(recall)
                    }
                }
            }
        }

        // Check for contextual nudges (upcoming meeting, long session, etc.)
        Task {
            if let nudge = await ContextualAwareness.shared.checkContext() {
                await MainActor.run {
                    // Only show if user hasn't started typing and no other state took over
                    if case .ready = self.inputBarState, self.currentInput.isEmpty {
                        self.contextualNudge = nudge
                    }
                }
            }
        }
    }

    func hideInputBar() {
        guard inputBarVisible else { return }
        print("[AppState] hideInputBar()")

        // Cancel voice if active
        if voiceActive {
            VoiceService.shared.cancel()
            voiceIntegration.hideGlow()
            voiceActive = false
        }

        // Cancel any running task
        currentTask?.cancel()
        currentTask = nil

        // Trigger SwiftUI float-up animation first, then hide the panel
        inputBarVisible = false
        inputBarState = .idle
        currentInput = ""

        // Delay panel hide so the float-up + fade animation plays out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.inputBarPanel?.hideBar()
        }
    }

    // MARK: - Research Detection

    // Only trigger research mode for explicit, intentional research requests
    private static let researchKeywords: [String] = [
        "research ", "deep dive ", "investigate ", "deep research ",
    ]

    private func looksLikeResearch(_ command: String) -> Bool {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Must start with an explicit research keyword — casual questions are NOT research
        return Self.researchKeywords.contains { lower.hasPrefix($0) }
    }

    /// Called when user picks Deep or Light research from the choice buttons.
    func submitResearch(query: String, mode: String) {
        let prefixed = "[\(mode) research] \(query)"
        inputBarState = .processing
        executeCommand(prefixed)
    }

    // MARK: - Browser Detection

    private static let browserKeywords: [String] = [
        "fill form", "fill out", "log in to", "login to", "sign up on", "sign in to",
        "book a", "book on", "order from", "order on", "purchase", "checkout",
        "add to cart", "submit form", "automate web", "go to", "navigate to",
        "browse to", "on the website", "on the site", "using the browser",
    ]

    private func looksLikeBrowserTask(_ command: String) -> Bool {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Must contain a browser-like keyword + a URL or site reference
        let hasBrowserKeyword = Self.browserKeywords.contains { lower.contains($0) }
        let hasSiteReference = lower.contains(".com") || lower.contains(".org") || lower.contains(".net")
            || lower.contains("http") || lower.contains("website") || lower.contains("site")
            || lower.contains("page") || lower.contains("browser")
        return hasBrowserKeyword && hasSiteReference
    }

    /// Called when user picks Watch or Background from the browser choice buttons.
    func submitBrowserTask(query: String, visible: Bool) {
        let prefixed = visible ? "[browser visible] \(query)" : "[browser background] \(query)"
        inputBarState = .processing
        executeCommand(prefixed)
    }

    // MARK: - Command Submission

    func submitCommand(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Handle internal commands (not user-facing)
        if command.hasPrefix("__internal_") {
            handleInternalCommand(command)
            return
        }

        // Agent routing — classify which agent should handle this command
        let routing = AgentRouter.route(command)
        if let agent = AgentRegistry.shared.profile(for: routing.agentId) {
            currentAgent = agent
        }
        let agentRouted = routing.strippedCommand

        // Resolve aliases before processing
        let resolvedCommand = AliasManager.shared.resolve(agentRouted)
        lastSubmittedPrompt = command

        // If within 60s of last result, treat as follow-up (skip research detection)
        let isFollowUp = Date().timeIntervalSince(lastCommandTime) < 60 && !conversationMessages.isEmpty

        // If it looks like research and not a follow-up, show the choice buttons
        if !isFollowUp && looksLikeResearch(resolvedCommand) {
            inputBarState = .researchChoice(query: resolvedCommand)
            return
        }

        // If it looks like a browser task, ask user if they want to watch
        if !isFollowUp && looksLikeBrowserTask(resolvedCommand) {
            inputBarState = .browserChoice(query: resolvedCommand)
            return
        }

        // Try local execution for simple commands (no API call needed)
        if !isFollowUp {
            inputBarState = .processing
            Task { [weak self] in
                // Tier 1: Local command routing (zero API, pattern matching)
                if let result = await LocalCommandRouter.shared.tryLocalExecution(resolvedCommand) {
                    await MainActor.run {
                        self?.inputBarState = .result(message: result)
                        CommandHistory.shared.add(command: resolvedCommand, result: result)
                    }
                    return
                }

                // Tier 2: Smart calculator (zero API, unit-aware math)
                if let result = SmartCalculator.evaluate(resolvedCommand) {
                    await MainActor.run {
                        self?.inputBarState = .result(message: result)
                        CommandHistory.shared.add(command: resolvedCommand, result: result)
                    }
                    return
                }

                // Tier 3: Formula database (zero API, local lookup)
                if let result = FormulaDatabase.shared.lookup(resolvedCommand) {
                    await MainActor.run {
                        self?.inputBarState = .result(message: result)
                        CommandHistory.shared.add(command: resolvedCommand, result: result)
                    }
                    return
                }

                // Tier 4: SmartRouter (minimal LLM call — single tool or direct answer)
                if let match = SmartRouter.shared.trySingleToolRoute(resolvedCommand) {
                    await self?.executeSmartRoute(resolvedCommand, match: match)
                    return
                }

                // Tier 5: Full AgentLoop
                await MainActor.run {
                    self?.executeCommand(resolvedCommand, isFollowUp: isFollowUp)
                }
            }
            return
        }

        inputBarState = .processing
        executeCommand(resolvedCommand, isFollowUp: isFollowUp)
    }

    /// Handles internal commands dispatched by TaskScheduler or other subsystems.
    private func handleInternalCommand(_ command: String) {
        switch command {
        case "__internal_verify_pending_skills":
            Task {
                let results = await SkillVerifier.shared.verifyAllPending()
                var promoted = 0
                var rejected = 0
                for result in results {
                    if result.status == .verified {
                        SkillsManager.shared.promoteSkill(named: result.skillName)
                        promoted += 1
                    } else {
                        SkillsManager.shared.rejectSkill(named: result.skillName, reason: result.rejectionReason ?? "Failed safety check")
                        rejected += 1
                    }
                }
                if promoted > 0 || rejected > 0 {
                    print("[SkillVerifier] Batch complete: \(promoted) promoted, \(rejected) rejected")
                    // Show notification to user
                    let message = "\(promoted) skill(s) verified and activated, \(rejected) rejected. Use list_pending_skills for details."
                    await MainActor.run { [weak self] in
                        self?.inputBarState = .result(message: "[Skill Verification Complete] \(message)")
                    }
                }
            }
        default:
            print("[AppState] Unknown internal command: \(command)")
        }
    }

    /// Executes a SmartRouter match: minimal LLM call with optional single tool.
    private func executeSmartRoute(_ command: String, match: SmartRouter.SingleToolMatch) async {
        // Check cache first
        if let cached = await ResponseCache.shared.get(command) {
            await MainActor.run { [weak self] in
                self?.inputBarState = .result(message: cached)
                CommandHistory.shared.add(command: command, result: cached)
            }
            return
        }

        do {
            let service = LLMServiceManager.shared.currentService
            let messages: [ChatMessage] = [
                ChatMessage(role: "system", content: match.minimalPrompt),
                ChatMessage(role: "user", content: command)
            ]
            let tools: [[String: AnyCodable]]? = match.toolName.flatMap {
                ToolRegistry.shared.singleToolSchema($0)
            }
            let response = try await service.sendChatRequest(
                messages: messages, tools: tools, maxTokens: match.maxTokens
            )

            // If the LLM wants to call a tool, execute it and send result back
            let finalText: String
            if let toolCalls = response.toolCalls, let first = toolCalls.first {
                let toolResult = try await ToolRegistry.shared.execute(toolName: first.function.name, arguments: first.function.arguments)
                // Send tool result back for formatting
                var followUp = messages
                followUp.append(response.rawMessage)
                followUp.append(ChatMessage(role: "tool", content: toolResult, tool_call_id: first.id))
                let formatted = try await service.sendChatRequest(
                    messages: followUp, tools: nil, maxTokens: match.maxTokens
                )
                finalText = formatted.text ?? toolResult
            } else {
                finalText = response.text ?? "No response."
            }

            // Cache the result
            await ResponseCache.shared.set(command, response: finalText)

            await MainActor.run { [weak self] in
                self?.inputBarState = .result(message: finalText)
                CommandHistory.shared.add(command: command, result: finalText)
            }
        } catch {
            // Fallback to full AgentLoop on error
            await MainActor.run { [weak self] in
                self?.executeCommand(command, isFollowUp: false)
            }
        }
    }

    private func executeCommand(_ resolvedCommand: String, isFollowUp: Bool = false) {
        currentTask?.cancel()
        let previousMessages = isFollowUp ? conversationMessages : []

        // Inject attached file contents into the command
        let fileContext = attachedFiles.map { $0.formattedForPrompt }.joined(separator: "\n\n")
        let fullCommand: String
        if !fileContext.isEmpty {
            fullCommand = "\(resolvedCommand)\n\nThe user has attached the following file(s) for context:\n\n\(fileContext)"
            // Clear attachments after use
            DispatchQueue.main.async { [weak self] in
                self?.attachedFiles.removeAll()
            }
        } else {
            fullCommand = resolvedCommand
        }

        currentTask = agentLoop.execute(
            fullCommand: fullCommand,
            resolvedCommand: resolvedCommand,
            previousMessages: previousMessages,
            agent: currentAgent.id == "general" ? nil : currentAgent,
            onStateChange: { [weak self] state in
                self?.inputBarState = state
            },
            onComplete: { [weak self] displayMessage, filteredText, messages in
                // Parse for structured display (dates, events, news, lists)
                let parsed = ResponseParser.parse(displayMessage)
                switch parsed {
                case .text:
                    self?.inputBarState = .result(message: displayMessage)
                default:
                    self?.inputBarState = .richResult(result: parsed, rawMessage: displayMessage)
                }
                self?.resultText = filteredText
                self?.conversationMessages = messages
                self?.lastCommandTime = Date()
                CommandHistory.shared.add(command: resolvedCommand, result: filteredText)
            },
            onError: { [weak self] errorMessage in
                self?.inputBarState = .error(message: errorMessage)
                self?.resultText = errorMessage
            }
        )
    }
}

// MARK: - VoiceIntegrationDelegate

extension AppState: VoiceIntegrationDelegate {
    func showInputBarPanel() {
        inputBarPanel?.showBar()
    }
}
