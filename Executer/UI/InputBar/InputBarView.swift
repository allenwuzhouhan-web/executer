import SwiftUI
import AppKit

struct InputBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isVisible = false
    @FocusState private var isTextFieldFocused: Bool

    @State private var isDragHovering = false

    // Result bubble state
    @State private var isSpeaking = false
    @State private var showCopied = false
    @State private var isHoveringResult = false
    @State private var typewriterText = ""
    @State private var typewriterTimer: Timer?
    @State private var autoDismissTask: Task<Void, Never>?

    // Speech synthesizer for read-aloud (shared instance to avoid re-creation)
    private static let synthesizer = NSSpeechSynthesizer()

    var body: some View {
        VStack(spacing: 0) {
            // Main input pill with file attachment badge
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                    .animation(.spring(response: 0.3), value: appState.inputBarState)

                if isEditable {
                    TextField("Ask anything...", text: $appState.currentInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            appState.submitCommand(appState.currentInput)
                        }
                } else {
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()
                }

                // File attachment badge — shows when files are attached
                if !appState.attachedFiles.isEmpty {
                    fileAttachmentBadge
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                ZStack {
                    VisualEffectBackground(material: .popover, blendingMode: .behindWindow, cornerRadius: 16)
                    shimmerOverlay

                    // Drag hover highlight
                    if isDragHovering {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.1))
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5, antialiased: true)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
                handleFileDrop(providers)
            }

            // Contextual nudge (upcoming meeting, break reminder, etc.)
            if let nudge = appState.contextualNudge,
               case .ready = appState.inputBarState, appState.currentInput.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 10, weight: .semibold))

                    Text(nudge)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Thought recall card
            if case .thoughtRecall(let recall) = appState.inputBarState {
                ThoughtRecallCard(recall: recall)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Research choice buttons
            if case .researchChoice(let query) = appState.inputBarState {
                researchChoiceButtons(query: query)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Prompt label + result bubble
            if case .result(let message) = appState.inputBarState {
                promptLabel
                resultBubble(message: message, isError: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if case .error(let message) = appState.inputBarState {
                promptLabel
                resultBubble(message: message, isError: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Health check card
            if case .healthCard(let message) = appState.inputBarState {
                healthCardBubble(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Handoff badge
            HandoffBadge()
        }
        .frame(width: 340, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(y: isVisible ? 0 : -30)
        .opacity(isVisible ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.inputBarState)
        .onAppear {
            isVisible = true
            isTextFieldFocused = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    // MARK: - File Attachment Badge

    private var fileAttachmentBadge: some View {
        Button {
            // Tap to remove all attachments
            withAnimation(.spring(response: 0.25)) {
                appState.attachedFiles.removeAll()
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                // Count badge
                Text("\(appState.attachedFiles.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .offset(x: 5, y: 4)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Click to remove attached files")
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                // Read file content off the main thread
                Task.detached {
                    if let attached = AttachedFile.from(url: url) {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.25)) {
                                if !self.appState.attachedFiles.contains(where: { $0.url == url }) {
                                    self.appState.attachedFiles.append(attached)
                                }
                            }
                        }
                    }
                }
            }
            handled = true
        }
        return handled
    }

    // MARK: - Subviews

    @ViewBuilder
    private func resultBubble(message: String, isError: Bool) -> some View {
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

    // MARK: - Result Bubble Actions

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
                appState.hideInputBar()
            }
        }
    }

    @ViewBuilder
    private func researchChoiceButtons(query: String) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.submitResearch(query: query, mode: "deep")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Deep Research")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                appState.submitResearch(query: query, mode: "light")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quick Lookup")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.1))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func healthCardBubble(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "heart.circle.fill")
                .foregroundStyle(.teal)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)

            ScrollView(.vertical, showsIndicators: false) {
                Text(message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        if appState.inputBarState == .processing || isExecuting || isVoiceListening {
            ShimmerView(animationSpeed: PersonalityEngine.shared.currentPersonality.animationSpeed)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(0.3)
        }
    }

    /// Shows what the user asked, above the result bubble.
    @ViewBuilder
    private var promptLabel: some View {
        if !appState.lastSubmittedPrompt.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(appState.lastSubmittedPrompt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    // MARK: - Computed Properties

    private var isVoiceListening: Bool {
        if case .voiceListening = appState.inputBarState { return true }
        return false
    }

    private var isEditable: Bool {
        switch appState.inputBarState {
        case .ready, .thoughtRecall: return true
        default: return false
        }
    }

    private var isExecuting: Bool {
        if case .executing = appState.inputBarState { return true }
        return false
    }

    private var statusText: String {
        let humor = HumorMode.shared
        switch appState.inputBarState {
        case .processing:
            return humor.isEnabled ? humor.funnyThinking() : "Thinking..."
        case .executing(let name, let step, let total):
            return humor.isEnabled ? humor.funnyToolStatus(toolName: name, step: step, total: total) : "Running \(name)... (\(step)/\(total))"
        case .researchChoice:
            return humor.isEnabled ? "Whatcha wanna know?" : "What kind of research?"
        case .voiceListening(let partial):
            if partial.isEmpty {
                return humor.isEnabled ? "I'm all ears, bestie" : "Listening..."
            }
            return partial
        case .thoughtRecall:
            return humor.isEnabled ? "Oh hey, you're back!" : "Welcome back"
        case .result(let msg):
            return humor.isEnabled ? humor.funnyResult(msg) : msg
        case .error(let msg): return msg
        case .healthCard(let msg): return msg
        default: return ""
        }
    }

    private var iconName: String {
        switch appState.inputBarState {
        case .ready: return "sparkle"
        case .processing: return "brain"
        case .executing: return "gearshape.2"
        case .voiceListening: return "mic.fill"
        case .researchChoice: return "magnifyingglass"
        case .thoughtRecall: return "brain.fill"
        case .result: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .healthCard: return "heart.circle.fill"
        case .idle: return "sparkle"
        }
    }

    private var iconColor: Color {
        let personality = PersonalityEngine.shared.currentPersonality
        switch appState.inputBarState {
        case .result: return .green
        case .error: return .red
        case .voiceListening: return .purple
        case .thoughtRecall: return .purple
        case .healthCard: return .teal
        default: return personality.accentColor
        }
    }
}
