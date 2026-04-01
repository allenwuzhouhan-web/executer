import SwiftUI
import AppKit

/// Rich card for news headlines — Apple News / Hacker News style blocks.
struct NewsResultCard: View {
    let headlines: [NewsHeadline]
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var hoveredIndex: Int?
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var isHovering = false

    private let accentColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                Text("Headlines")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

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
            .padding(.bottom, 8)

            // Gradient divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.4), .purple.opacity(0.4), .orange.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Headlines list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(headlines.enumerated()), id: \.element.id) { index, headline in
                        headlineRow(headline: headline, index: index)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 8)
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.8)
                                    .delay(Double(index) * 0.08),
                                value: appeared
                            )
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 240)

            // Footer
            HStack {
                Text("\(headlines.count) headlines")
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
                .strokeBorder(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .purple.opacity(0.2), .orange.opacity(0.15), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .blue.opacity(0.08), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(.top, 6)
        .onHover { isHovering = $0 }
        .onAppear {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            withAnimation { appeared = true }
            scheduleAutoDismiss()
        }
        .onDisappear { autoDismissTask?.cancel() }
    }

    @ViewBuilder
    private func headlineRow(headline: NewsHeadline, index: Int) -> some View {
        let accent = accentColors[index % accentColors.count]

        Button {
            if let urlString = headline.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Accent bar
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(headline.source)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .textCase(.uppercase)

                        if let timeAgo = headline.timeAgo {
                            Text(timeAgo)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.quaternary)
                        }
                    }

                    if !headline.summary.isEmpty {
                        Text(headline.summary)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredIndex == index ? Color.primary.opacity(0.04) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !isHovering else { return }
            await MainActor.run { onDismiss() }
        }
    }
}
