import SwiftUI

/// Dropdown menu for manually switching between agent profiles.
struct AgentPickerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentRegistry.shared.allProfiles(), id: \.id) { profile in
                Button {
                    AgentRegistry.shared.setActive(profile.id)
                    appState.currentAgent = profile
                } label: {
                    HStack {
                        Image(systemName: profile.icon)
                        Text(profile.displayName)
                        if appState.currentAgent.id == profile.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: appState.currentAgent.color) ?? .white)
                    .frame(width: 8, height: 8)

                Text(appState.currentAgent.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Hex Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r, g, b: Double
        switch hexSanitized.count {
        case 6:
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
        case 8:
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
        default:
            return nil
        }

        self.init(red: r, green: g, blue: b)
    }
}
