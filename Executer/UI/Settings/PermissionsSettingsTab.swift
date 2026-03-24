import SwiftUI

struct PermissionsSettingsTab: View {
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        Form {
            Section("Required Permissions") {
                permissionRow(
                    name: "Accessibility",
                    description: "Required for system control and window management",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )

                permissionRow(
                    name: "Input Monitoring",
                    description: "Required for notch click detection (CGEvent tap)",
                    granted: permissions.eventTapAvailable,
                    action: { permissions.requestEventTapAccess() }
                )

                permissionRow(
                    name: "Notifications",
                    description: "Timer alerts, status notifications",
                    granted: permissions.notificationsGranted,
                    action: { permissions.requestNotifications() }
                )

                permissionRow(
                    name: "Automation (Apple Events)",
                    description: "Required for controlling apps via AppleScript (Music, System Events, etc.)",
                    granted: permissions.appleEventsGranted,
                    action: { permissions.openAutomationSettings() }
                )
            }

            Section {
                Button("Refresh Permission Status") {
                    permissions.checkAll()
                }

                Text("After granting permissions in System Settings, click Refresh or restart the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Grant When Prompted") {
                Text("These are requested automatically when first needed:")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Label("Calendar & Reminders", systemImage: "calendar")
                Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissions.checkAll()
        }
    }

    private func permissionRow(name: String, description: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }
}
