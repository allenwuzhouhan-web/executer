import SwiftUI
import Cocoa

struct ThoughtRecallCard: View {
    let recall: ThoughtRecall
    @EnvironmentObject var appState: AppState
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: app icon + dismiss
            HStack(spacing: 8) {
                appIcon
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(recall.appName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(timeAgoText)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .liquidGlassCircle()
                }
                .buttonStyle(.plain)
            }

            // Summary
            Text(recall.summary)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    resumeInApp()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.left.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Resume")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    finishWithAI()
                } label: {
                    HStack(spacing: 4) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(isGenerating ? "Writing..." : "Finish with AI")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 12, tint: .purple)
        .shadow(color: .purple.opacity(0.06), radius: 8, y: 4)
        .padding(.top, 6)
        .task {
            // Auto-dismiss after 10 seconds if user hasn't interacted
            try? await Task.sleep(for: .seconds(10))
            if case .thoughtRecall = appState.inputBarState {
                dismiss()
            }
        }
    }

    // MARK: - Computed

    private var appIcon: Image {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: recall.appBundleId) {
            let nsImage = NSWorkspace.shared.icon(forFile: appURL.path)
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "app.fill")
    }

    private var timeAgoText: String {
        let minutes = Int(recall.timeElapsed / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: - Actions

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appState.inputBarState = .ready
        }
    }

    private func resumeInApp() {
        ThoughtRecallService.shared.markComplete(recall)

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: recall.appBundleId) {
            NSWorkspace.shared.open(url)
        }

        appState.hideInputBar()
    }

    private func finishWithAI() {
        isGenerating = true

        Task {
            guard let completion = await ThoughtRecallService.shared.generateCompletion(for: recall) else {
                await MainActor.run {
                    isGenerating = false
                    appState.inputBarState = .error(message: "Could not generate completion")
                }
                return
            }

            await MainActor.run {
                // Copy completion to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(completion, forType: .string)

                ThoughtRecallService.shared.markComplete(recall)

                // Reopen the app
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: recall.appBundleId) {
                    NSWorkspace.shared.open(url)
                }

                // Brief delay then paste
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Simulate Cmd+V to paste
                    let source = CGEventSource(stateID: .hidSystemState)
                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
                    keyDown?.flags = .maskCommand
                    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
                    keyUp?.flags = .maskCommand
                    keyDown?.post(tap: .cghidEventTap)
                    keyUp?.post(tap: .cghidEventTap)
                }

                appState.inputBarState = .result(message: "AI completion pasted")
            }
        }
    }
}
