import Cocoa
import Speech
import AVFoundation
import Combine
import Accelerate

/// Voice input service with always-on background listening for wake word detection.
/// Uses audio level monitoring (VAD) to detect speech, then spins up short SFSpeech
/// sessions to check for the wake word. This avoids the ~1 minute SFSpeech timeout issue.
class VoiceService: ObservableObject {
    static let shared = VoiceService()

    @Published var state: VoiceState = .idle
    @Published var partialTranscription: String = ""

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voice_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "voice_enabled")
            if newValue && alwaysListening {
                startBackgroundListening()
            } else if !newValue {
                stopBackgroundListening()
            }
        }
    }

    var alwaysListening: Bool {
        get { UserDefaults.standard.bool(forKey: "voice_always_listening") }
        set {
            UserDefaults.standard.set(newValue, forKey: "voice_always_listening")
            if newValue && isEnabled {
                startBackgroundListening()
            } else if !newValue {
                stopBackgroundListening()
            }
        }
    }

    /// Called by AppState when the final command text is ready.
    var onCommandComplete: ((String) -> Void)?
    /// Called when wake word is detected during background listening.
    var onWakeWordDetected: (() -> Void)?

    // Audio engine — shared across background and command modes
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastSegmentCount = 0
    private var retryCount = 0
    private let maxRetries = 1
    private var wasBackgroundListening = false

    // Background listening (VAD-based)
    private var backgroundEngine: AVAudioEngine?
    private var isBackgroundActive = false
    private var speechDetectionTask: SFSpeechRecognitionTask?
    private var speechDetectionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var vadSpeechStartTime: Date?
    private var vadSessionTimer: Timer?
    private var vadCooldown = false
    /// Rolling RMS power level for voice activity detection
    private var currentPowerLevel: Float = -160.0
    /// Threshold above which we consider "someone is speaking" (in dB)
    private let vadThreshold: Float = -35.0
    /// How many consecutive frames above threshold to trigger speech detection
    private var framesAboveThreshold = 0
    private let framesNeededToTrigger = 4 // ~100ms at 1024 buffer / 44.1kHz

    private init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        speechRecognizer.defaultTaskHint = .dictation

        if speechRecognizer.supportsOnDeviceRecognition {
            print("[Voice] On-device recognition available for \(speechRecognizer.locale.identifier)")
        }
    }

    // MARK: - Public

    /// Start always-on background listening for wake word.
    func startBackgroundListening() {
        guard isEnabled, alwaysListening else { return }
        guard !isBackgroundActive else { return }
        guard state == .idle else { return }

        Task {
            let authorized = await requestPermissions()
            guard authorized else {
                print("[Voice] Permissions not granted for background listening")
                return
            }
            DispatchQueue.main.async {
                self.beginBackgroundVAD()
            }
        }
    }

    /// Stop background listening entirely.
    func stopBackgroundListening() {
        tearDownBackgroundVAD()
        if state == .backgroundListening {
            state = .idle
        }
    }

    /// Activate voice mode on demand (hotkey).
    func activate() async {
        guard state == .idle || state == .backgroundListening else { return }

        wasBackgroundListening = isBackgroundActive

        // Tear down background listening — we're taking over the mic
        tearDownBackgroundVAD()

        let authorized = await requestPermissions()
        guard authorized else {
            print("[Voice] Permissions not granted")
            DispatchQueue.main.async { self.state = .error("Microphone or speech recognition permission denied") }
            return
        }

        DispatchQueue.main.async {
            self.retryCount = 0
            self.state = .activated
            self.partialTranscription = ""
            print("[Voice] Activated — starting command listening")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startCommandListening()
            }
        }
    }

    func stop() {
        cancelCurrentSession()
        DispatchQueue.main.async {
            self.state = .idle
            self.partialTranscription = ""
            self.resumeBackgroundListeningIfNeeded()
        }
    }

    func cancel() {
        cancelCurrentSession()
        DispatchQueue.main.async {
            self.state = .idle
            self.partialTranscription = ""
            self.resumeBackgroundListeningIfNeeded()
        }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let micGranted: Bool
        if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = true
        }
        guard micGranted else { return false }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return speechGranted
    }

    // MARK: - Background VAD (Voice Activity Detection)

    /// Keeps the mic running at very low cost. Only monitors audio levels.
    /// When speech is detected, spins up a short SFSpeech session to check for wake word.
    private func beginBackgroundVAD() {
        guard !isBackgroundActive else { return }
        guard backgroundEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("[Voice] Invalid audio format — cannot start background listening")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBackgroundAudioBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Voice] Failed to start background VAD: \(error)")
            inputNode.removeTap(onBus: 0)
            backgroundEngine = nil
            return
        }

        backgroundEngine = engine
        isBackgroundActive = true
        state = .backgroundListening
        framesAboveThreshold = 0
        vadCooldown = false
        print("[Voice] Background VAD started — listening for speech activity")
    }

    /// Tear down the background VAD engine.
    private func tearDownBackgroundVAD() {
        vadSessionTimer?.invalidate()
        vadSessionTimer = nil
        tearDownSpeechDetection()

        if let engine = backgroundEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        backgroundEngine = nil
        isBackgroundActive = false
        framesAboveThreshold = 0
        vadCooldown = false
    }

    /// Process each audio buffer to compute RMS power level.
    private func processBackgroundAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Compute RMS power
        var rms: Float = 0
        vDSP_measqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let power = rms > 0 ? 10 * log10(rms) : -160.0

        // Check against threshold
        if power > vadThreshold {
            framesAboveThreshold += 1
            if framesAboveThreshold >= framesNeededToTrigger && !vadCooldown {
                framesAboveThreshold = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechActivityDetected()
                }
            }
        } else {
            framesAboveThreshold = max(0, framesAboveThreshold - 1)
        }
    }

    /// Called when we detect someone is speaking. Spins up a short recognition session.
    private func onSpeechActivityDetected() {
        guard isBackgroundActive, state == .backgroundListening else { return }
        guard speechDetectionTask == nil else { return } // Already running a detection session
        vadCooldown = true

        print("[Voice] Speech activity detected — starting recognition check")
        vadSpeechStartTime = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't force on-device — let the system choose for reliability
        request.addsPunctuation = false
        speechDetectionRequest = request

        // Feed audio from the already-running background engine into this recognition request
        guard let engine = backgroundEngine else { return }
        let inputNode = engine.inputNode

        // Remove old tap, install new one that feeds both VAD and recognition
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBackgroundAudioBuffer(buffer)
            self?.speechDetectionRequest?.append(buffer)
        }

        speechDetectionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.isBackgroundActive else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                if self.containsWakeWord(lower) {
                    print("[Voice] Wake word detected: \"\(text)\"")
                    DispatchQueue.main.async {
                        let commandAfterWake = AssistantNameManager.shared.stripNamePrefix(from: text)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        self.tearDownBackgroundVAD()
                        self.wasBackgroundListening = true
                        self.state = .activated
                        self.partialTranscription = commandAfterWake
                        self.onWakeWordDetected?()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.startCommandListening()
                        }
                    }
                    return
                }

                // If final result with no wake word, end this detection session
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.endSpeechDetectionSession()
                    }
                }
            }

            if error != nil {
                DispatchQueue.main.async {
                    self.endSpeechDetectionSession()
                }
            }
        }

        // Kill the detection session after 5 seconds max — don't let it linger
        vadSessionTimer?.invalidate()
        vadSessionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.endSpeechDetectionSession()
        }
    }

    /// End the short speech detection session and go back to VAD-only mode.
    private func endSpeechDetectionSession() {
        tearDownSpeechDetection()

        // Re-install VAD-only tap
        guard let engine = backgroundEngine, engine.isRunning else {
            // Engine died — restart everything
            isBackgroundActive = false
            state = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startBackgroundListening()
            }
            return
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBackgroundAudioBuffer(buffer)
        }

        // Brief cooldown to avoid rapid re-triggers
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.vadCooldown = false
        }

        print("[Voice] Detection session ended — back to VAD monitoring")
    }

    /// Clean up just the speech detection task/request (not the background engine).
    private func tearDownSpeechDetection() {
        vadSessionTimer?.invalidate()
        vadSessionTimer = nil
        speechDetectionTask?.cancel()
        speechDetectionTask = nil
        speechDetectionRequest?.endAudio()
        speechDetectionRequest = nil
    }

    /// Check if the transcribed text contains the assistant's wake word.
    private func containsWakeWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        let name = AssistantNameManager.shared.name.lowercased()

        if lower.contains(name) { return true }

        for variant in AssistantNameManager.shared.learnedVariants {
            if lower.contains(variant) { return true }
        }

        return false
    }

    /// Resume background listening if it was active before.
    private func resumeBackgroundListeningIfNeeded() {
        if wasBackgroundListening || (isEnabled && alwaysListening) {
            wasBackgroundListening = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.state == .idle else { return }
                self.startBackgroundListening()
            }
        }
    }

    // MARK: - Command Listening

    private func startCommandListening() {
        guard state == .activated || state == .listening else { return }

        state = .listening
        lastSegmentCount = 0
        print("[Voice] Mic on — listening for command")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        // Install tap before prepare/start
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Voice] Failed to start audio engine: \(error)")
            state = .error("Audio engine failed")
            return
        }

        audioEngine = engine

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.state == .listening else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let segmentCount = result.bestTranscription.segments.count

                DispatchQueue.main.async {
                    let stripped = AssistantNameManager.shared.stripNamePrefix(from: text)
                    self.partialTranscription = stripped

                    let lower = stripped.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower == "cancel" || lower == "never mind" || lower == "nevermind" {
                        print("[Voice] User cancelled via speech")
                        self.cancel()
                        return
                    }

                    if segmentCount > self.lastSegmentCount {
                        self.lastSegmentCount = segmentCount
                        self.resetSilenceTimer()
                    }
                }

                if result.isFinal {
                    DispatchQueue.main.async {
                        self.finishCommand(text)
                    }
                }
            }

            if let error = error as NSError? {
                print("[Voice] Recognition error: \(error.domain) code \(error.code)")
                DispatchQueue.main.async {
                    if !self.partialTranscription.isEmpty {
                        self.finishCommand(self.partialTranscription)
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        print("[Voice] Retrying recognition (attempt \(self.retryCount + 1))")
                        self.cancelCurrentSession()
                        self.state = .activated
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.startCommandListening()
                        }
                    } else {
                        self.cancel()
                    }
                }
            }
        }

        // Silence timer: 2.5s of no new speech = command complete
        resetSilenceTimer()

        // Absolute timeout: 12 seconds
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .listening else { return }
            if !self.partialTranscription.isEmpty {
                self.finishCommand(self.partialTranscription)
            } else {
                self.cancel()
            }
        }
    }

    private func finishCommand(_ command: String) {
        let stripped = AssistantNameManager.shared.stripNamePrefix(from: command)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            return
        }

        cancelCurrentSession()
        state = .dispatched
        print("[Voice] Mic off — command: \"\(trimmed)\"")

        onCommandComplete?(trimmed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.state = .idle
            self?.resumeBackgroundListeningIfNeeded()
        }
    }

    // MARK: - Timers

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .listening else { return }
            if !self.partialTranscription.isEmpty {
                self.finishCommand(self.partialTranscription)
            }
        }
    }

    // MARK: - Session Management

    private func cancelCurrentSession() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
    }
}
