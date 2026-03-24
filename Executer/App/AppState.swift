import SwiftUI
import Combine
import Carbon

enum InputBarState: Equatable {
    case idle
    case ready
    case processing
    case executing(toolName: String, step: Int, total: Int)
    case result(message: String)
    case error(message: String)
    case researchChoice(query: String)
    case thoughtRecall(ThoughtRecall)
    case healthCard(message: String)
    case voiceListening(partial: String)
}

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
    private var hotkeyRef: EventHotKeyRef?
    private var voiceHotkeyRef: EventHotKeyRef?
    private var lastToggleTime: Date = .distantPast
    private var voiceGlowWindow: VoiceGlowWindow?
    private var voiceCancellables = Set<AnyCancellable>()

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

        registerGlobalHotkey()
        setupVoiceSubscriptions()
        print("[AppState] setup() complete")
    }

    // MARK: - Voice Integration

    private func setupVoiceSubscriptions() {
        let voice = VoiceService.shared

        voice.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .listening:
                    self.voiceGlowWindow?.updatePulseIntensity(.listening)
                case .error:
                    self.handleVoiceCancellation()
                default:
                    break
                }
            }
            .store(in: &voiceCancellables)

        voice.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                if case .voiceListening = self.inputBarState {
                    self.inputBarState = .voiceListening(partial: text)
                }
            }
            .store(in: &voiceCancellables)

        voice.onCommandComplete = { [weak self] command in
            DispatchQueue.main.async {
                self?.handleVoiceCommandComplete(command)
            }
        }

        // When wake word is detected during background listening, show the UI
        voice.onWakeWordDetected = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Don't interrupt active commands
                switch self.inputBarState {
                case .processing, .executing:
                    print("[Voice] Command already running, ignoring wake word")
                    return
                default:
                    break
                }
                self.handleVoiceActivation()
            }
        }

        // Start background listening on launch if enabled
        voice.startBackgroundListening()
    }

    /// Triggered by Cmd+Shift+V. Starts mic, shows glow, listens for one command, then stops mic.
    func activateVoice() {
        guard VoiceService.shared.isEnabled else {
            print("[Voice] Voice not enabled in settings")
            return
        }
        // Don't interrupt active commands
        switch inputBarState {
        case .processing, .executing:
            print("[Voice] Command already running, ignoring")
            return
        default:
            break
        }
        // If already in voice mode, cancel it
        if voiceActive {
            handleVoiceCancellation()
            return
        }

        handleVoiceActivation()
        Task { await VoiceService.shared.activate() }
    }

    private func handleVoiceActivation() {
        voiceActive = true

        voiceGlowWindow = VoiceGlowWindow()
        voiceGlowWindow?.show()
        voiceGlowWindow?.updatePulseIntensity(.activated)

        // Show input bar in voice mode
        if !inputBarVisible {
            inputBarVisible = true
            inputBarPanel?.showBar()
        }
        inputBarState = .voiceListening(partial: "")
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func handleVoiceCommandComplete(_ command: String) {
        voiceGlowWindow?.hide()
        voiceActive = false

        currentInput = command
        inputBarState = .processing
        submitCommand(command)
    }

    func handleVoiceCancellation() {
        if voiceActive {
            VoiceService.shared.cancel()
            voiceGlowWindow?.hide()
            voiceActive = false
        }
        if case .voiceListening = inputBarState {
            hideInputBar()
        }
    }

    func updateNotchZone(_ rect: CGRect) {
        print("[AppState] updateNotchZone: \(rect), detector is \(notchDetector == nil ? "nil" : "alive")")
        notchDetector?.setCustomZone(rect)
    }

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
            voiceGlowWindow?.hide()
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

        currentTask = Task.detached { [weak self] in
            do {
                let manager = LLMServiceManager.shared
                let registry = ToolRegistry.shared
                let context = SystemContext.current()
                let tools = registry.toolDefinitions()

                let isDeepResearch = fullCommand.hasPrefix("[deep research]")
                let maxIterations = 15
                let maxTokens = isDeepResearch ? 8192 : 2048

                // Build message chain — reuse previous for follow-ups
                var messages: [ChatMessage]
                if !previousMessages.isEmpty {
                    messages = previousMessages
                    messages.append(ChatMessage(role: "user", content: fullCommand))
                } else {
                    messages = [
                        ChatMessage(role: "system", content: manager.fullSystemPrompt(context: context, query: fullCommand)),
                        ChatMessage(role: "user", content: fullCommand)
                    ]
                }

                var finalText = "Done."

                // Multi-turn agent loop: LLM can call tools, see results, then call more tools
                for iteration in 0..<maxIterations {
                    // Check for cancellation before each iteration
                    if Task.isCancelled {
                        print("[Agent] Task cancelled at iteration \(iteration + 1)")
                        return
                    }

                    print("[Agent] Iteration \(iteration + 1)/\(maxIterations) — sending \(messages.count) messages")

                    let response = try await manager.currentService.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )

                    guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                        // No tool calls — LLM is done, use its text as the final response
                        finalText = response.text ?? "Done."
                        print("[Agent] No tool calls — final response: \(finalText)")
                        break
                    }

                    // Append the assistant's message (contains tool_calls)
                    messages.append(response.rawMessage)

                    // Execute each tool call and append results
                    for call in toolCalls {
                        if Task.isCancelled {
                            print("[Agent] Task cancelled during tool execution")
                            return
                        }

                        let friendlyNames: [String: String] = [
                            "launch_app": "Opening app", "quit_app": "Closing app",
                            "click": "Clicking", "click_element": "Clicking",
                            "type_text": "Typing", "press_key": "Pressing key",
                            "hotkey": "Shortcut", "scroll": "Scrolling",
                            "move_cursor": "Moving cursor", "drag": "Dragging",
                            "capture_screen": "Looking", "ocr_image": "Reading screen",
                            "open_url": "Opening URL", "open_url_in_safari": "Opening Safari",
                            "search_web": "Searching", "dictionary_lookup": "Looking up",
                            "music_play_song": "Playing", "music_pause": "Pausing",
                        ]
                        let displayName = friendlyNames[call.function.name] ?? call.function.name
                        print("[Agent] Tool call: \(call.function.name)(\(call.function.arguments))")
                        await MainActor.run {
                            self?.inputBarState = .executing(toolName: displayName, step: iteration + 1, total: maxIterations)
                        }

                        let result: String
                        do {
                            result = try await registry.execute(
                                toolName: call.function.name,
                                arguments: call.function.arguments
                            )
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }
                        print("[Agent] Result: \(result)")

                        // Brief delay after UI interaction tools so the OS processes each action
                        if call.function.name == "launch_app" {
                            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s for app launch
                        } else if ["click", "click_element", "type_text", "press_key", "hotkey", "scroll", "move_cursor"].contains(call.function.name) {
                            try await Task.sleep(nanoseconds: 200_000_000) // 200ms for UI actions
                        }

                        messages.append(ChatMessage(
                            role: "tool",
                            content: result,
                            tool_call_id: call.id
                        ))
                    }
                    // Loop continues — LLM sees tool results and can call more tools or finish
                }

                // Apply personality post-filter before display
                let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)

                // Show result inline — no file dumping
                let displayMessage = filteredText

                // Save to handoff (use unfiltered text for full content)
                HandoffService.shared.saveHandoff(
                    command: resolvedCommand,
                    response: finalText,
                    appContext: context.frontmostApp
                )

                await MainActor.run {
                    self?.inputBarState = .result(message: displayMessage)
                    self?.resultText = filteredText
                    self?.conversationMessages = messages
                    self?.lastCommandTime = Date()
                    CommandHistory.shared.add(command: resolvedCommand, result: filteredText)
                }

                // No auto-dismiss — user closes with Escape / hotkey / notch click
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.inputBarState = .error(message: error.localizedDescription)
                    self?.resultText = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Global Hotkey (Carbon API — works system-wide)

    private func registerGlobalHotkey() {
        // Install a Carbon event handler for hotkey events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let appState = Unmanaged<AppState>.fromOpaque(userData).takeUnretainedValue()

            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

            if hotkeyID.id == 1 {
                DispatchQueue.main.async {
                    print("[Hotkey] Cmd+Shift+Space pressed!")
                    appState.toggleInputBar()
                }
            } else if hotkeyID.id == 2 {
                DispatchQueue.main.async {
                    print("[Hotkey] Cmd+Shift+V pressed — voice!")
                    appState.activateVoice()
                }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, nil)

        // Register Cmd+Shift+Space
        // Space = keycode 49, Cmd = cmdKey, Shift = shiftKey
        var hotkeyID = EventHotKeyID(signature: OSType(0x4558_4543), id: 1) // "EXEC"
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)

        let status = RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &hotkeyRef)

        if status == noErr {
            print("[Hotkey] Registered Cmd+Shift+Space successfully")
        } else {
            print("[Hotkey] Failed to register hotkey, status: \(status)")
        }

        // Register Cmd+Shift+V for voice input
        // V = keycode 9
        var voiceHotkeyID = EventHotKeyID(signature: OSType(0x4558_4543), id: 2) // "EXEC" id 2
        let voiceStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, voiceHotkeyID,
                                              GetApplicationEventTarget(), 0, &voiceHotkeyRef)
        if voiceStatus == noErr {
            print("[Hotkey] Registered Cmd+Shift+V (voice) successfully")
        } else {
            print("[Hotkey] Failed to register voice hotkey, status: \(voiceStatus)")
        }
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = voiceHotkeyRef { UnregisterEventHotKey(ref) }
    }
}

struct SystemContext {
    let frontmostApp: String
    let currentTime: String
    let isDarkMode: Bool
    let volumeLevel: Int
    let clipboardPreview: String?
    let frontmostWindowTitle: String?
    let terminalCWD: String?
    let finderSelection: String?
    let batteryLevel: Int?
    let wifiNetworkName: String?
    let activeDisplayCount: Int
    let focusMode: String?

    static func current() -> SystemContext {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let time = formatter.string(from: Date())

        let darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        let volume = AppleScriptRunner.run("output volume of (get volume settings)") ?? "50"

        // Clipboard preview (first 200 chars)
        let clipboard: String? = {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
            let preview = text.prefix(200)
            return preview.count < text.count ? "\(preview)..." : String(preview)
        }()

        // Frontmost window title
        let windowTitle: String? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            let script = "tell application \"System Events\" to get name of front window of (first process whose unix id is \(app.processIdentifier))"
            return AppleScriptRunner.run(script)
        }()

        // Terminal CWD (if Terminal is frontmost)
        let cwd: String? = {
            guard frontApp == "Terminal" else { return nil }
            return AppleScriptRunner.run("tell application \"Terminal\" to get custom title of selected tab of front window")
        }()

        // Finder selection (if Finder is frontmost)
        let finderSel: String? = {
            guard frontApp == "Finder" else { return nil }
            return AppleScriptRunner.run("tell application \"Finder\" to get POSIX path of (selection as alias)")
        }()

        // Battery level
        let battery: Int? = {
            guard let result = try? ShellRunner.run("pmset -g batt", timeout: 5) else { return nil }
            guard let range = result.output.range(of: #"\d+%"#, options: .regularExpression) else { return nil }
            let pctStr = String(result.output[range]).replacingOccurrences(of: "%", with: "")
            return Int(pctStr)
        }()

        // Wi-Fi network name
        let wifi: String? = {
            guard let result = try? ShellRunner.run("networksetup -getairportnetwork en0", timeout: 5) else { return nil }
            if result.output.contains("Current Wi-Fi Network:") {
                return result.output.replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        // Display count
        let displayCount = NSScreen.screens.count

        // Focus mode
        let focus = FocusStateService.shared.currentFocus
        let focusStr: String? = focus == .none ? nil : focus.displayName

        return SystemContext(
            frontmostApp: frontApp,
            currentTime: time,
            isDarkMode: darkMode,
            volumeLevel: Int(volume) ?? 50,
            clipboardPreview: clipboard,
            frontmostWindowTitle: windowTitle,
            terminalCWD: cwd,
            finderSelection: finderSel,
            batteryLevel: battery,
            wifiNetworkName: wifi,
            activeDisplayCount: displayCount,
            focusMode: focusStr
        )
    }

    var systemPromptAddendum: String {
        var lines = [
            "Current context:",
            "- Frontmost app: \(frontmostApp)",
            "- Time: \(currentTime)",
            "- Dark mode: \(isDarkMode ? "on" : "off")",
            "- Volume: \(volumeLevel)%",
        ]
        if let title = frontmostWindowTitle {
            lines.append("- Window title: \(title)")
        }
        if let clipboard = clipboardPreview {
            lines.append("- Clipboard: \(clipboard)")
        }
        if let cwd = terminalCWD {
            lines.append("- Terminal CWD: \(cwd)")
        }
        if let sel = finderSelection {
            lines.append("- Finder selection: \(sel)")
        }
        if let battery = batteryLevel {
            lines.append("- Battery: \(battery)%")
        }
        if let wifi = wifiNetworkName {
            lines.append("- Wi-Fi: \(wifi)")
        }
        if activeDisplayCount > 1 {
            lines.append("- Displays: \(activeDisplayCount)")
        }
        if let focus = focusMode {
            lines.append("- Focus mode: \(focus)")
        }

        // Include top-level Documents folder structure so the AI knows where files are
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let docsPath = "\(home)/Documents"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: docsPath) {
            let folders = contents
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .prefix(30)
            if !folders.isEmpty {
                lines.append("- Documents folders: \(folders.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
