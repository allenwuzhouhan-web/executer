import SwiftUI

struct HandoffBadge: View {
    @ObservedObject private var handoffService = HandoffService.shared
    @State private var visible = false

    var body: some View {
        Group {
            if visible, let (icon, label) = badgeContent {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: visible)
        .onChange(of: handoffService.lastSyncStatus) { _, newStatus in
            switch newStatus {
            case .synced, .savedLocally:
                visible = true
                // Auto-hide after 3 seconds
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    visible = false
                }
            default:
                break
            }
        }
    }

    private var badgeContent: (icon: String, label: String)? {
        switch handoffService.lastSyncStatus {
        case .synced:
            return ("icloud.and.arrow.up", "Synced")
        case .savedLocally:
            return ("internaldrive", "Saved locally")
        default:
            return nil
        }
    }
}
