import Combine
import AppKit

/// Delegate protocol for VoiceIntegration to communicate back to AppState.
protocol VoiceIntegrationDelegate: AnyObject {
    var inputBarState: InputBarState { get set }
    var inputBarVisible: Bool { get set }
    var voiceActive: Bool { get set }
    var currentInput: String { get set }

    func showInputBarPanel()  // Just shows the panel window, no state reset
    func hideInputBar()
    func submitCommand(_ command: String)
}

/// Manages voice subscription setup, activation, cancellation, and glow window.
/// Extracted from AppState to isolate voice concerns.
class VoiceIntegration {
    weak var delegate: VoiceIntegrationDelegate?

    private var voiceGlowWindow: VoiceGlowWindow?
    private var voiceCancellables = Set<AnyCancellable>()

    func setup() {
        let voice = VoiceService.shared

        voice.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .listening:
                    self.voiceGlowWindow?.updatePulseIntensity(.listening)
                case .error:
                    self.handleCancellation()
                default:
                    break
                }
            }
            .store(in: &voiceCancellables)

        voice.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self, let delegate = self.delegate else { return }
                if case .voiceListening = delegate.inputBarState {
                    delegate.inputBarState = .voiceListening(partial: text)
                }
            }
            .store(in: &voiceCancellables)

        voice.onCommandComplete = { [weak self] command in
            DispatchQueue.main.async {
                self?.handleCommandComplete(command)
            }
        }

        // When wake word is detected during background listening, show the UI
        voice.onWakeWordDetected = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, let delegate = self.delegate else { return }
                // Don't interrupt active commands
                switch delegate.inputBarState {
                case .processing, .executing:
                    print("[Voice] Command already running, ignoring wake word")
                    return
                default:
                    break
                }
                self.handleActivation()
            }
        }

        // Start background listening on launch if enabled
        voice.startBackgroundListening()
    }

    /// Triggered by Cmd+Shift+V. Starts mic, shows glow, listens for one command, then stops mic.
    func activate() {
        guard let delegate = delegate else { return }
        guard VoiceService.shared.isEnabled else {
            print("[Voice] Voice not enabled in settings")
            return
        }
        // Don't interrupt active commands
        switch delegate.inputBarState {
        case .processing, .executing:
            print("[Voice] Command already running, ignoring")
            return
        default:
            break
        }
        // If already in voice mode, cancel it
        if delegate.voiceActive {
            handleCancellation()
            return
        }

        handleActivation()
        Task { await VoiceService.shared.activate() }
    }

    func handleActivation() {
        guard let delegate = delegate else { return }
        delegate.voiceActive = true

        voiceGlowWindow = VoiceGlowWindow()
        voiceGlowWindow?.show()
        voiceGlowWindow?.updatePulseIntensity(.activated)

        // Show input bar in voice mode
        if !delegate.inputBarVisible {
            delegate.inputBarVisible = true
            delegate.showInputBarPanel()
        }
        delegate.inputBarState = .voiceListening(partial: "")
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func handleCommandComplete(_ command: String) {
        guard let delegate = delegate else { return }
        voiceGlowWindow?.hide()
        delegate.voiceActive = false

        delegate.currentInput = command
        delegate.inputBarState = .processing
        delegate.submitCommand(command)
    }

    func handleCancellation() {
        guard let delegate = delegate else { return }
        if delegate.voiceActive {
            VoiceService.shared.cancel()
            voiceGlowWindow?.hide()
            delegate.voiceActive = false
        }
        if case .voiceListening = delegate.inputBarState {
            delegate.hideInputBar()
        }
    }

    func hideGlow() {
        voiceGlowWindow?.hide()
    }
}
