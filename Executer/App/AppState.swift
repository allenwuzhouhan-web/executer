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

    func showInputBar() {
        guard !inputBarVisible else { return }
        print("[AppState] showInputBar()")
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

    // MARK: - Command Submission

    func submitCommand(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Resolve aliases before processing
        let resolvedCommand = AliasManager.shared.resolve(command)
        lastSubmittedPrompt = command

        // If within 60s of last result, treat as follow-up (skip research detection)
        let isFollowUp = Date().timeIntervalSince(lastCommandTime) < 60 && !conversationMessages.isEmpty

        // If it looks like research and not a follow-up, show the choice buttons
        if !isFollowUp && looksLikeResearch(resolvedCommand) {
            inputBarState = .researchChoice(query: resolvedCommand)
            return
        }

        // Try local execution for simple commands (no API call needed)
        if !isFollowUp {
            inputBarState = .processing
            Task { [weak self] in
                if let result = await LocalCommandRouter.shared.tryLocalExecution(resolvedCommand) {
                    await MainActor.run {
                        self?.inputBarState = .result(message: result)
                        CommandHistory.shared.add(command: resolvedCommand, result: result)
                        // No auto-dismiss — user closes with Escape / hotkey / notch click
                    }
                    return
                }
                // Not a simple command — fall through to LLM
                await MainActor.run {
                    self?.executeCommand(resolvedCommand, isFollowUp: isFollowUp)
                }
            }
            return
        }

        inputBarState = .processing
        executeCommand(resolvedCommand, isFollowUp: isFollowUp)
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
            onStateChange: { [weak self] state in
                self?.inputBarState = state
            },
            onComplete: { [weak self] displayMessage, filteredText, messages in
                self?.inputBarState = .result(message: displayMessage)
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
