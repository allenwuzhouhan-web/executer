import SwiftUI

struct AboutSettingsTab: View {
    @ObservedObject private var llmManager = LLMServiceManager.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Executer")
                .font(.title.bold())

            if AppModel.isPrerelease {
                Text(AppModel.buildType.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.orange)
                    .cornerRadius(6)
            }

            Text("Click the notch. Command your Mac.")
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Model: \(AppModel.modelNumber)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Version: \(AppModel.version) (\(AppModel.buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Serial: \(DeviceSerial.serial)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Text("Powered by \(llmManager.currentProvider.config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider().padding(.horizontal, 40)

            // Inline update section
            UpdateSettingsTab()
                .frame(maxHeight: 120)

            Spacer()

            HStack(spacing: 16) {
                Text("\(ToolRegistry.shared.count) tools")
                Text("\(AgentRegistry.shared.allProfiles().count) agents")
                Text("\(DocumentStudyStore.shared.profiles.count) trained docs")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if AppModel.isPrerelease {
                DeveloperSettingsTab()
                    .frame(maxHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
