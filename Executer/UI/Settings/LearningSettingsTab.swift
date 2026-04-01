import SwiftUI

struct LearningSettingsTab: View {
    @State private var isLearningEnabled = LearningConfig.shared.isLearningEnabled
    @State private var isObservationEnabled = LearningConfig.shared.isObservationEnabled
    @State private var isScreenSamplingEnabled = LearningConfig.shared.isScreenSamplingEnabled
    @State private var blockedApps = AppAllowlist.blockedApps()
    @State private var showClearConfirmation = false
    @State private var isContextInjectionEnabled = LearningConfig.shared.isContextInjectionEnabled

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
                        Text("Sampling rate")
                        Spacer()
                        Text(AdaptiveSampling.shared.statusDescription())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Sampling is adaptive: aggressive during the first week to learn your workflows, then relaxes over time. Key apps (PowerPoint, Keynote) get boosted sampling automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Observation", systemImage: "eye")
            }

            Section {
                Toggle("Inject learned context into prompts", isOn: $isContextInjectionEnabled)
                    .onChange(of: isContextInjectionEnabled) { _, newValue in
                        LearningConfig.shared.isContextInjectionEnabled = newValue
                    }
                Text("When ON, your learned patterns are included in AI prompts for better answers. When OFF, learning still observes but doesn't affect responses (saves tokens).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Observation (screen, apps, files, clipboard)")
                        Spacer()
                        Text("FREE")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Pattern extraction & session detection")
                        Spacer()
                        Text("FREE")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Context injection per AI prompt")
                        Spacer()
                        Text("~$0.002")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Image(systemName: "dollarsign.circle")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("Learning overhead today")
                        Spacer()
                        Text("\(CostTracker.shared.learningTokensToday) tokens")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.caption)
            } header: {
                Label("Cost Impact", systemImage: "dollarsign.circle")
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

            Section {
                DocumentDropbox()
            } header: {
                Label("Document Trainer", systemImage: "brain.head.profile")
            }
        }
        .formStyle(.grouped)
    }
}
