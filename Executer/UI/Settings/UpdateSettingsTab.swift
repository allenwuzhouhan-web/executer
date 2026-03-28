import SwiftUI

struct UpdateSettingsTab: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("Current Version") {
                HStack {
                    Text("Executer")
                        .font(.headline)
                    Spacer()
                    Text("v\(updater.currentVersion)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Updates") {
                if updater.isUpdating {
                    // Update in progress
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(updater.updateStatus)
                                .font(.subheadline)
                        }
                        ProgressView(value: updater.updateProgress)
                            .progressViewStyle(.linear)
                    }
                } else if updater.updateAvailable, let latest = updater.latestVersion {
                    // Update available
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Update Available")
                                    .font(.headline)
                            }
                            Text("v\(updater.currentVersion) → v\(latest)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Update Now") {
                            updater.performUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("Your API keys and permissions are saved securely and will persist after the update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Up to date or checking
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("You're up to date")
                                    .font(.headline)
                            }
                            if updater.isChecking {
                                Text("Checking for updates...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button("Check for Updates") {
                            updater.checkForUpdates()
                        }
                        .disabled(updater.isChecking)
                    }
                }
            }

            if !updater.updateStatus.isEmpty && updater.updateStatus.contains("failed") {
                Section("Error") {
                    Text(updater.updateStatus)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("API keys are stored in the macOS Keychain and persist across updates. Accessibility and other permissions are retained as long as the app stays in the same location.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if !updater.isChecking && !updater.updateAvailable {
                updater.checkForUpdates()
            }
        }
    }
}
