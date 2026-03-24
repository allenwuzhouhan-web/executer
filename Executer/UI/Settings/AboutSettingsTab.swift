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

            Text("Click the notch. Command your Mac.")
                .foregroundStyle(.secondary)

            Text("Powered by \(llmManager.currentProvider.config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(ToolRegistry.shared.count) tools available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
