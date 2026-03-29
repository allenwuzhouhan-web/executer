import SwiftUI

/// Developer settings — only visible in pre-release builds.
/// Gives access to internal diagnostics, learning internals, and debug tools.
struct DeveloperSettingsTab: View {
    @State private var showResetOnboarding = false
    @State private var integrityStatus = "Not checked"
    @State private var samplingStatus = AdaptiveSampling.shared.statusDescription()

    var body: some View {
        Form {
            Section {
                LabeledContent("Model") { Text(AppModel.modelNumber).font(.system(.body, design: .monospaced)) }
                LabeledContent("Build") { Text("\(AppModel.version) (\(AppModel.buildNumber))").font(.system(.body, design: .monospaced)) }
                LabeledContent("Type") {
                    Text(AppModel.buildType.rawValue)
                        .foregroundStyle(.orange)
                        .fontWeight(.bold)
                }
                LabeledContent("Serial") {
                    Text(DeviceSerial.serial)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Label("Build Info", systemImage: "hammer")
            }

            Section {
                LabeledContent("Integrity") { Text(integrityStatus).foregroundStyle(integrityStatus == "Passed" ? .green : .red) }
                Button("Run Integrity Check") {
                    let result = IntegrityChecker.verify()
                    if case .passed = result { integrityStatus = "Passed" }
                    else if case .failed(let r) = result { integrityStatus = "FAILED: \(r)" }
                }
                LabeledContent("Sampling") { Text(samplingStatus).font(.caption) }
                Button("Refresh Sampling") {
                    AdaptiveSampling.shared.recalculateInterval()
                    samplingStatus = AdaptiveSampling.shared.statusDescription()
                }
            } header: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Section {
                LabeledContent("Learning DB") {
                    let apps = LearningManager.shared.learnedApps
                    Text("\(apps.count) apps, \(apps.reduce(0) { $0 + $1.actionCount }) actions")
                        .font(.caption)
                }
                LabeledContent("Goals") { Text("\(GoalTracker.shared.topGoals(limit: 100).count) active") }
                LabeledContent("Templates") { Text("\(TemplateLibrary.shared.all().count) saved") }
                LabeledContent("Predictions") { Text(PredictionEvaluator.shared.summary()).font(.caption) }
                LabeledContent("Cost Today") { Text(CostTracker.shared.dailyReport()).font(.caption) }
            } header: {
                Label("Learning Internals", systemImage: "brain")
            }

            Section {
                Button("Reset Welcome Screen") { showResetOnboarding = true }
                    .alert("Reset Onboarding?", isPresented: $showResetOnboarding) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            UserDefaults.standard.removeObject(forKey: "has_completed_onboarding")
                            LearningOnboarding.reset()
                        }
                    } message: { Text("The welcome screen will show again on next launch.") }

                Button("Force Daily Summary") {
                    SummaryScheduler.shared.generateNow()
                }

                Button("Boost Learning (10 min)") {
                    AdaptiveSampling.shared.boostForApp("Manual Boost")
                    samplingStatus = AdaptiveSampling.shared.statusDescription()
                }
            } header: {
                Label("Actions", systemImage: "wrench.and.screwdriver")
            }

            Section {
                LabeledContent("Ollama") {
                    Text("localhost:11434")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("Check Ollama Status") {
                    Task {
                        let available = await OllamaRouter.shared.isAvailable()
                        integrityStatus = available ? "Ollama: Running" : "Ollama: Not running"
                    }
                }
            } header: {
                Label("Local Model", systemImage: "desktopcomputer")
            }
        }
        .formStyle(.grouped)
    }
}
