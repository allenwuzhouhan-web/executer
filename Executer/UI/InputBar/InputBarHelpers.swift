import SwiftUI

/// Computed properties and small helper views for InputBarView.
extension InputBarView {
    var isVoiceListening: Bool {
        if case .voiceListening = appState.inputBarState { return true }
        return false
    }

    var isEditable: Bool {
        switch appState.inputBarState {
        case .ready, .thoughtRecall: return true
        default: return false
        }
    }

    var isExecuting: Bool {
        if case .executing = appState.inputBarState { return true }
        return false
    }

    var statusText: String {
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

    var iconName: String {
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

    var iconColor: Color {
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

    @ViewBuilder
    var shimmerOverlay: some View {
        if appState.inputBarState == .processing || isExecuting || isVoiceListening {
            ShimmerView(animationSpeed: PersonalityEngine.shared.currentPersonality.animationSpeed)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(0.3)
        }
    }

    @ViewBuilder
    var promptLabel: some View {
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
}
