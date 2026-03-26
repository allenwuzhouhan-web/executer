import SwiftUI

/// Confirmation card shown before sending a message via WeChat or iMessage.
/// Displays recipient, message preview, and Send/Cancel buttons.
struct WeChatConfirmCard: View {
    let recipient: String
    let messageText: String
    let platform: MessageRouter.MessagePlatform
    let onSend: () -> Void
    let onCancel: () -> Void

    private var platformColor: Color {
        platform == .wechat ? Color(red: 0.027, green: 0.757, blue: 0.373) : .blue
    }

    private var platformLabel: String {
        platform == .wechat ? "WeChat" : "iMessage"
    }

    private var platformIcon: String {
        platform == .wechat ? "bubble.left.fill" : "message.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: platform badge + recipient
            HStack(spacing: 8) {
                Image(systemName: platformIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(platformColor)

                Text(platformLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(platformColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(platformColor.opacity(0.15))
                    .cornerRadius(4)

                Spacer()

                Text("To: \(recipient)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }

            // Message preview
            Text(messageText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onSend) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                        Text("Send")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(platformColor)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        )
    }
}
