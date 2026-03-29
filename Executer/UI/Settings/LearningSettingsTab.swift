import SwiftUI

struct LearningSettingsTab: View {
    @State private var isLearningEnabled = LearningConfig.shared.isLearningEnabled
    @State private var isObservationEnabled = LearningConfig.shared.isObservationEnabled
    @State private var isScreenSamplingEnabled = LearningConfig.shared.isScreenSamplingEnabled
    @State private var screenSamplingInterval = LearningConfig.shared.screenSamplingInterval
    @State private var blockedApps = AppAllowlist.blockedApps()
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Learning", isOn: $isLearningEnabled)
                    .onChange(of: isLearningEnabled) { _, newValue in
                        LearningConfig.shared.isLearningEnabled = newValue
                        if newValue {
                            LearningManager.shared.start()
                        } else {
                            LearningManager.shared.stop()
                        }
                    }
                Text("When enabled, Executer silently observes your app usage to learn your workflows and preferences. All data stays local.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Learning Engine", systemImage: "brain")
            }

            Section {
                Toggle("Observe App Actions", isOn: $isObservationEnabled)
                    .onChange(of: isObservationEnabled) { _, newValue in
                        LearningConfig.shared.isObservationEnabled = newValue
                    }
                Toggle("Periodic Screen Sampling", isOn: $isScreenSamplingEnabled)
                    .onChange(of: isScreenSamplingEnabled) { _, newValue in
                        LearningConfig.shared.isScreenSamplingEnabled = newValue
                    }
                if isScreenSamplingEnabled {
                    HStack {
                        Text("Sampling interval")
                        Spacer()
                        Picker("", selection: $screenSamplingInterval) {
                            Text("30s").tag(30.0)
                            Text("60s").tag(60.0)
                            Text("120s").tag(120.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .onChange(of: screenSamplingInterval) { _, newValue in
                            LearningConfig.shared.screenSamplingInterval = newValue
                        }
                    }
                }
            } header: {
                Label("Observation", systemImage: "eye")
            }

            Section {
                if blockedApps.isEmpty {
                    Text("No apps blocked — all apps are observed.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(blockedApps, id: \.self) { bundleId in
                        HStack {
                            Text(bundleId)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Unblock") {
                                AppAllowlist.unblock(bundleId)
                                blockedApps = AppAllowlist.blockedApps()
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.blue)
                        }
                    }
                }
                Text("Block apps by bundle ID to prevent learning from observing them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Blocked Apps", systemImage: "hand.raised")
            }

            Section {
                let apps = LearningManager.shared.learnedApps
                if apps.isEmpty {
                    Text("No data collected yet. Use your Mac normally and check back later.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(apps, id: \.name) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text("\(app.patternCount) patterns")
                                .foregroundColor(.secondary)
                            Text("·")
                                .foregroundColor(.secondary)
                            Text("\(app.actionCount) actions")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Label("Learned Data", systemImage: "chart.bar")
            }

            Section {
                Button("Clear All Learned Data", role: .destructive) {
                    showClearConfirmation = true
                }
                .alert("Clear All Data?", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Everything", role: .destructive) {
                        LearningManager.shared.clearAll()
                        GoalTracker.shared.clearAll()
                    }
                } message: {
                    Text("This will permanently delete all learned patterns, goals, and observations. This cannot be undone.")
                }
            } header: {
                Label("Data Management", systemImage: "trash")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy")
                        .font(.headline)
                    Text("• Observations store categories and lengths, never raw text")
                    Text("• Password fields are always skipped")
                    Text("• All data encrypted at rest (AES-256)")
                    Text("• Nothing is sent to external servers")
                    Text("• You can delete everything at any time")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
