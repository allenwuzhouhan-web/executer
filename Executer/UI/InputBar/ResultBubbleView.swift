import SwiftUI
import AppKit

struct ResultBubbleView: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    @State private var isSpeaking = false
    @State private var showCopied = false
    @State private var isHoveringResult = false
    @State private var typewriterText = ""
    @State private var typewriterTimer: Timer?
    @State private var autoDismissTask: Task<Void, Never>?

    // Speech synthesizer for read-aloud (shared instance to avoid re-creation)
    private static let synthesizer = NSSpeechSynthesizer()

    var body: some View {
        let isShort = message.count < 100
        let displayText = isShort ? typewriterText : message

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    if let attributed = try? AttributedString(markdown: isShort ? displayText : message,
                                                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(isShort ? displayText : message)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 200)

                // Action buttons
                if !isError {
                    VStack(spacing: 4) {
                        // Read aloud
                        Button {
                            toggleSpeech(message)
                        } label: {
                            Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isSpeaking ? "Stop reading" : "Read aloud")

                        // Copy
                        Button {
                            copyToClipboard(message)
                        } label: {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(showCopied ? .green : .secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                                .animation(.spring(response: 0.25), value: showCopied)
                        }
                        .buttonStyle(.plain)
                        .help("Copy response")
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            // Rainbow glow border — outside clipShape so the glow bleeds outward
            if !isError {
                ResponseGlowView(cornerRadius: 12)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .padding(.top, 6)
        .onHover { hovering in
            isHoveringResult = hovering
        }
        .onAppear {
            // Haptic feedback
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)

            // Typewriter effect for short messages
            if isShort {
                startTypewriter(message)
            }

            // Auto-dismiss for very short confirmations
            if message.count < 30 && !isError {
                scheduleAutoDismiss()
            }
        }
        .onDisappear {
            stopSpeech()
            typewriterTimer?.invalidate()
            typewriterTimer = nil
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    // MARK: - Actions

    private func toggleSpeech(_ text: String) {
        if isSpeaking {
            stopSpeech()
        } else {
            // Strip markdown for speech
            let plain = text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "##", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "_", with: "")
            Self.synthesizer.startSpeaking(plain)
            isSpeaking = true

            // Poll for completion
            Task {
                while Self.synthesizer.isSpeaking == true {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run { isSpeaking = false }
            }
        }
    }

    private func stopSpeech() {
        Self.synthesizer.stopSpeaking()
        isSpeaking = false
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    private func startTypewriter(_ message: String) {
        typewriterText = ""
        let chars = Array(message)
        let totalDuration = min(0.5, Double(chars.count) * 0.015)
        let interval = totalDuration / Double(chars.count)
        var index = 0

        typewriterTimer?.invalidate()
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            if index < chars.count {
                typewriterText.append(chars[index])
                index += 1
            } else {
                timer.invalidate()
            }
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
            guard !Task.isCancelled, !isHoveringResult else { return }
            await MainActor.run {
                onDismiss()
            }
        }
    }
}
