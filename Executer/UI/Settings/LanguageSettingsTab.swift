import SwiftUI

struct LanguageSettingsTab: View {
    @State private var selectedLanguage: AppLanguage = LanguageManager.shared.currentLanguage
    @State private var humorEnabled: Bool = HumorMode.shared.isEnabled

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Language & Humor")
                    .font(.title2.bold())

                Text("Choose the language for AI responses and humor messages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Language Grid
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        languageCard(lang)
                    }
                }

                Divider()

                // Humor Mode Toggle
                Toggle(isOn: $humorEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Humor Mode")
                            .font(.headline)
                        Text("Your Mac becomes your unhinged best friend.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: humorEnabled) { _, newValue in
                    HumorMode.shared.isEnabled = newValue
                }

                // Humor Preview
                if humorEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preview")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        let msgs = selectedLanguage.humorMessages
                        if let thinking = msgs.thinkingMessages.first {
                            previewRow(label: "Thinking:", text: thinking)
                        }
                        if let success = msgs.successPrefixes.first {
                            previewRow(label: "Success:", text: "\(success)Opened Safari.")
                        }
                        if let healthy = msgs.healthyMessages.first {
                            previewRow(label: "Health:", text: healthy)
                        }
                    }
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.background)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Language Card

    @ViewBuilder
    private func languageCard(_ lang: AppLanguage) -> some View {
        let isSelected = selectedLanguage == lang

        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedLanguage = lang
                LanguageManager.shared.currentLanguage = lang
            }
        } label: {
            VStack(spacing: 6) {
                Text(lang.flag)
                    .font(.system(size: 36))
                Text(lang.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(lang.nativeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 16))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview Row

    @ViewBuilder
    private func previewRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
