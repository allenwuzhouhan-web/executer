import Cocoa
import Speech
import AVFoundation

/// Records voice samples of the user saying the assistant name, runs them through
/// SFSpeechRecognizer to learn how the recognizer transcribes this user's voice,
/// and stores the variants for better matching.
class VoiceCalibration: ObservableObject {
    static let shared = VoiceCalibration()

    @Published var calibrationState: CalibrationState = .idle
    @Published var currentPrompt: String = ""
    @Published var samplesRecorded: Int = 0
    @Published var lastHeard: String = ""

    enum CalibrationState: Equatable {
        case idle
        case waitingToRecord(sample: Int)
        case recording(sample: Int)
        case processing
        case done
        case error(String)
    }

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingTimer: Timer?
    private var isProcessingSample = false

    private let totalSamples = 3
    private let prompts = [
        "Say \"%@\"",
        "Say \"Hey %@\"",
        "Say \"Help %@\"",
    ]

    private init() {}

    var isCalibrated: Bool {
        !AssistantNameManager.shared.learnedVariants.isEmpty
    }

    /// Start the calibration flow.
    func startCalibration() {
        AssistantNameManager.shared.clearLearnedVariants()
        samplesRecorded = 0
        lastHeard = ""
        isProcessingSample = false
        promptNextSample()
    }

    func cancelCalibration() {
        tearDownAudio()
        calibrationState = .idle
        currentPrompt = ""
        lastHeard = ""
        isProcessingSample = false
    }

    private func promptNextSample() {
        let idx = samplesRecorded
        guard idx < totalSamples else {
            calibrationState = .done
            currentPrompt = ""
            print("[Calibration] Complete — variants: \(AssistantNameManager.shared.learnedVariants)")
            return
        }

        let name = AssistantNameManager.shared.name
        currentPrompt = String(format: prompts[idx], name)
        lastHeard = ""
        isProcessingSample = false
        calibrationState = .waitingToRecord(sample: idx + 1)

        // Auto-start recording after a brief UI pause
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            if case .waitingToRecord = self.calibrationState {
                self.beginRecording(sampleIndex: idx)
            }
        }
    }

    private func beginRecording(sampleIndex: Int) {
        // Create a fresh audio engine each time to avoid stale state
        tearDownAudio()

        let engine = AVAudioEngine()
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!

        self.audioEngine = engine
        self.speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        // Install tap before prepare/start so the engine knows about connected nodes
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDownAudio()
            calibrationState = .error("Mic failed: \(error.localizedDescription)")
            return
        }

        calibrationState = .recording(sample: sampleIndex + 1)

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, !self.isProcessingSample else { return }
            guard case .recording = self.calibrationState else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.lastHeard = text
                }
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.commitSample(text)
                    }
                }
            }

            if error != nil, !self.isProcessingSample {
                DispatchQueue.main.async {
                    if !self.lastHeard.isEmpty {
                        self.commitSample(self.lastHeard)
                    }
                    // If nothing heard, the timer will handle it
                }
            }
        }

        // Auto-commit after 4 seconds
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.isProcessingSample else { return }
            if !self.lastHeard.isEmpty {
                self.commitSample(self.lastHeard)
            } else {
                // Nothing heard — skip and retry this sample
                self.tearDownAudio()
                self.promptNextSample()
            }
        }
    }

    private func commitSample(_ transcription: String) {
        guard !isProcessingSample else { return }
        isProcessingSample = true

        tearDownAudio()
        calibrationState = .processing
        lastHeard = transcription

        // Extract words as variants
        let words = transcription.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        let fillers: Set<String> = [
            "hey", "help", "say", "the", "a", "an", "oh", "um", "uh",
            "like", "yo", "ok", "okay", "bro", "hi", "hello",
        ]
        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            if !cleaned.isEmpty && !fillers.contains(cleaned) && cleaned.count >= 2 {
                AssistantNameManager.shared.addLearnedVariant(cleaned)
            }
        }

        // Full phrase too
        let full = transcription.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        if !full.isEmpty {
            AssistantNameManager.shared.addLearnedVariant(full)
        }

        samplesRecorded += 1
        print("[Calibration] Sample \(samplesRecorded)/\(totalSamples): \"\(transcription)\"")

        // Next sample after a pause
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.promptNextSample()
        }
    }

    private func tearDownAudio() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        speechRecognizer = nil
    }
}
