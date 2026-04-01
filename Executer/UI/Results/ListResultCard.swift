import SwiftUI
import AppKit

/// Rich card for structured list responses — numbered items with optional details.
struct ListResultCard: View {
    let title: String?
    let items: [ListItem]
    let rawMessage: String
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var showCopied = false
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.teal)

                if let title = title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                // Copy all
                Button {
                    copyAll()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(showCopied ? .green : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)

            // List items
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemRow(item: item, index: index)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 6)
                            .animation(
                                .spring(response: 0.35, dampingFraction: 0.8)
                                    .delay(Double(index) * 0.04),
                                value: appeared
                            )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)

            // Footer
            HStack {
                Text("\(items.count) items")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .padding(.top, 4)
        }
        .background { VisualEffectBackground(material: .popover, blendingMode: .behindWindow) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .teal.opacity(0.06), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(.top, 6)
        .onHover { isHovering = $0 }
        .onAppear {
            withAnimation { appeared = true }
            scheduleAutoDismiss()
        }
        .onDisappear { autoDismissTask?.cancel() }
    }

    @ViewBuilder
    private func itemRow(item: ListItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.teal)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)

                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(index % 2 == 0 ? Color.primary.opacity(0.02) : .clear)
        )
    }

    private func copyAll() {
        let text = items.enumerated().map { i, item in
            var line = "\(i + 1). \(item.text)"
            if let detail = item.detail { line += " - \(detail)" }
            return line
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !isHovering else { return }
            await MainActor.run { onDismiss() }
        }
    }
}
