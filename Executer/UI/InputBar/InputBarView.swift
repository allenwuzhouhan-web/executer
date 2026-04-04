import SwiftUI
import AppKit

struct InputBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var browserTrailStore = BrowserTrailStore.shared
    @State private var isVisible = false
    @FocusState private var isTextFieldFocused: Bool

    @State private var isDragHovering = false
    @Namespace private var glassNS

    var body: some View {
        VStack(spacing: 0) {
            // Main input pill with file attachment badge
            HStack(spacing: 8) {
                // Agent indicator dot — visible when a non-general agent is active
                if appState.currentAgent.id != "general" {
                    Circle()
                        .fill(Color(hex: appState.currentAgent.color) ?? .white)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                }

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
            .liquidGlassInteractive(cornerRadius: 16)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
                handleFileDrop(providers)
            }
            .liquidGlassID("input", in: glassNS)

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

            // Browser visibility choice buttons
            if case .browserChoice(let query) = appState.inputBarState {
                browserChoiceButtons(query: query)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Browser trail card (always shown when available, independent of LLM response)
            if !browserTrailStore.currentTrail.isEmpty {
                BrowserTrailCard(
                    trail: browserTrailStore.currentTrail,
                    onDismiss: { browserTrailStore.currentTrail = [] }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Prompt label + result bubble
            if case .result(let message) = appState.inputBarState {
                promptLabel
                ResultBubbleView(message: message, isError: false, onDismiss: { appState.hideInputBar() })
                    .liquidGlassID("result", in: glassNS)
                    .liquidGlassMaterialize()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Rich result cards (date, event, news, list)
            if case .richResult(let result, let raw) = appState.inputBarState {
                promptLabel
                RichResultView(result: result, rawMessage: raw, onDismiss: { appState.hideInputBar() })
                    .liquidGlassID("richResult", in: glassNS)
                    .liquidGlassMaterialize()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if case .error(let message) = appState.inputBarState {
                promptLabel
                ResultBubbleView(message: message, isError: true, onDismiss: { appState.hideInputBar() })
                    .liquidGlassID("error", in: glassNS)
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
        .liquidGlassContainer(spacing: 16)
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

    // MARK: - Small Subviews

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
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.15))
                .liquidGlassInteractive(cornerRadius: 10, tint: .accentColor)
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
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.1))
                .liquidGlassInteractive(cornerRadius: 10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func browserChoiceButtons(query: String) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.submitBrowserTask(query: query, visible: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Watch")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(Color.blue)
                .background(Color.blue.opacity(0.15))
                .liquidGlassInteractive(cornerRadius: 10, tint: .blue)
            }
            .buttonStyle(.plain)

            Button {
                appState.submitBrowserTask(query: query, visible: false)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Background")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.1))
                .liquidGlassInteractive(cornerRadius: 10)
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
        .liquidGlass(cornerRadius: 12, tint: .teal)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
        .padding(.top, 6)
    }
}
