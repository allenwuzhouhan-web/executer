import SwiftUI

/// Card that renders a coworking suggestion in the InputBar.
/// Modeled after ThoughtRecallCard — same layout pattern with accept/dismiss buttons.
struct CoworkingSuggestionCard: View {
    let suggestion: CoworkingSuggestion
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + type label + dismiss
            HStack(spacing: 8) {
                Image(systemName: iconForType)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(labelForType)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

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

            // Headline
            Text(suggestion.headline)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Detail (optional)
            if let detail = suggestion.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    accept()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(acceptButtonLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Not now")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 12, tint: .orange)
        .shadow(color: .orange.opacity(0.06), radius: 8, y: 4)
        .padding(.top, 6)
        .task {
            // Auto-dismiss when suggestion expires
            let remaining = suggestion.expiresAt.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if case .coworkingSuggestion = appState.inputBarState {
                dismiss()
            }
        }
    }

    // MARK: - Actions

    private func accept() {
        let hasAction = suggestion.actionCommand != nil && !suggestion.actionCommand!.isEmpty
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            CoworkerAgent.shared.acceptSuggestion(suggestion)
            // Only reset to .ready if there's no action command.
            // When there IS an action, submitCommand() sets .processing —
            // overwriting that to .ready is why the card vanished with no feedback.
            if !hasAction {
                appState.inputBarState = .ready
            }
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            CoworkerAgent.shared.dismissSuggestion()
            appState.inputBarState = .ready
        }
    }

    // MARK: - Type-specific styling

    private var acceptButtonLabel: String {
        if suggestion.actionCommand == nil { return "Got it" }
        switch suggestion.type {
        case .workspaceFocus: return "Help me"
        case .contextualHelp: return "Help me"
        case .workflowAutomation: return "Automate it"
        default: return "Do it"
        }
    }

    private var iconForType: String {
        switch suggestion.type {
        case .goalNudge: return "target"
        case .meetingPrep: return "calendar.badge.clock"
        case .breakReminder: return "cup.and.saucer.fill"
        case .clipboardAssist: return "doc.on.clipboard"
        case .fileOrganization: return "folder.badge.gearshape"
        case .workflowAutomation: return "arrow.triangle.2.circlepath"
        case .contextualHelp: return "lightbulb.fill"
        case .routine: return "clock.fill"
        case .deadlineAlert: return "exclamationmark.triangle.fill"
        case .synthesis: return "link.circle.fill"
        case .workspaceFocus: return "squares.leading.rectangle"
        }
    }

    private var labelForType: String {
        switch suggestion.type {
        case .goalNudge: return "Goal"
        case .meetingPrep: return "Meeting"
        case .breakReminder: return "Break"
        case .clipboardAssist: return "Clipboard"
        case .fileOrganization: return "Files"
        case .workflowAutomation: return "Workflow"
        case .contextualHelp: return "Help"
        case .routine: return "Routine"
        case .deadlineAlert: return "Deadline"
        case .synthesis: return "Connection"
        case .workspaceFocus: return "Workspace"
        }
    }
}
