import SwiftUI

/// One-time permission setup shown on first launch (or whenever core permissions are missing).
/// Auto-closes when both Accessibility and Input Monitoring are granted.
/// Once granted, macOS remembers them forever — the user never sees this again.
struct PermissionSetupView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var pollTimer: Timer?
    var onComplete: () -> Void

    private var allGranted: Bool {
        permissions.accessibilityGranted && permissions.eventTapAvailable
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Executer Setup")
                    .font(.title.bold())

                Text("Grant these two permissions once — you'll never be asked again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Permission steps
            VStack(spacing: 16) {
                permissionStep(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    why: "Window control, WeChat automation, keyboard shortcuts",
                    howTo: "Find \"Executer\" in the list and flip the toggle ON.",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )

                permissionStep(
                    icon: "keyboard",
                    name: "Input Monitoring",
                    why: "Notch clicks, global hotkeys, event capture",
                    howTo: "Find \"Executer\" in the list and flip the toggle ON.",
                    granted: permissions.eventTapAvailable,
                    action: { permissions.requestEventTapAccess() }
                )
            }

            // Status
            if allGranted {
                Label("All set! Starting Executer...", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                Text("This window will close automatically once both are granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 460, height: 420)
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
        .onChange(of: allGranted) { _, granted in
            if granted {
                pollTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    onComplete()
                }
            }
        }
    }

    // MARK: - Subviews

    private func permissionStep(icon: String, name: String, why: String, howTo: String,
                                granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary)
                if !granted {
                    Text(howTo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if !granted {
                Button("Open Settings") { action() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(granted ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            PermissionManager.shared.refreshAccessibility()
            PermissionManager.shared.refreshEventTap()
        }
    }
}

// PermissionSetupWindowController removed — unified into OnboardingWindowController
