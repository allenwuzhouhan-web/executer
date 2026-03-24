import AVFoundation

/// Synthesizes and plays a subtle, beautiful startup chime.
/// A short ascending chord (C-E-G) with soft sine tones and gentle fade.
class StartupSound {

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    func play() {
        let engine = AVAudioEngine()
        let sampleRate: Double = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Chord: C5 (523Hz), E5 (659Hz), G5 (784Hz) — a gentle major triad
        // Each note enters slightly staggered for an arpeggio feel
        let notes: [(freq: Double, startSample: Int, duration: Double)] = [
            (523.25, 0, 1.2),         // C5 — starts immediately
            (659.25, 3300, 1.0),      // E5 — starts 75ms later
            (783.99, 6600, 0.8),      // G5 — starts 150ms later
            (1046.50, 8800, 0.6),     // C6 — gentle octave sparkle
        ]

        let totalDuration: Double = 1.6
        let totalSamples = Int(sampleRate * totalDuration)
        var sampleCounter = 0

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                let currentSample = sampleCounter + frame

                guard currentSample < totalSamples else {
                    if let buffer = ablPointer.first {
                        let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)
                        ptr?[frame] = 0
                    }
                    continue
                }

                var sample: Float = 0

                for note in notes {
                    let noteSample = currentSample - note.startSample
                    guard noteSample >= 0 else { continue }

                    let noteDurationSamples = Int(note.duration * sampleRate)
                    guard noteSample < noteDurationSamples else { continue }

                    let t = Double(noteSample) / sampleRate
                    let phase = 2.0 * Double.pi * note.freq * t

                    // Sine wave with soft overtone
                    var tone = sin(phase) * 0.6
                    tone += sin(phase * 2.0) * 0.1  // gentle 2nd harmonic
                    tone += sin(phase * 3.0) * 0.03 // whisper of 3rd harmonic

                    // Envelope: quick attack, long decay
                    let attack: Double = 0.02
                    let noteProgress = t / note.duration
                    let envelope: Double
                    if t < attack {
                        envelope = t / attack
                    } else {
                        // Exponential decay for natural feel
                        let decayProgress = (t - attack) / (note.duration - attack)
                        envelope = pow(1.0 - decayProgress, 2.0)
                    }

                    sample += Float(tone * envelope * 0.15) // 0.15 = subtle master volume
                }

                if let buffer = ablPointer.first {
                    let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)
                    ptr?[frame] = sample
                }
            }

            sampleCounter += Int(frameCount)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            print("[StartupSound] Failed to start audio engine: \(error)")
            return
        }

        self.audioEngine = engine
        self.sourceNode = source

        // Stop after the sound completes
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.2) { [weak self] in
            self?.audioEngine?.stop()
            if let src = self?.sourceNode {
                self?.audioEngine?.detach(src)
            }
            self?.audioEngine = nil
            self?.sourceNode = nil
        }
    }
}
