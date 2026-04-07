import SwiftUI
import AppKit

/// Rich card showing the URL trail after a browser task completes.
struct BrowserTrailCard: View {
    let trail: [BrowserTrailEntry]
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var hoveredIndex: Int?
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var isHovering = false

    private let accentColors: [Color] = [
        .teal, .blue, .cyan, .mint, .indigo, .purple
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                Text("Browser Trail")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .liquidGlassCircle()
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
                        colors: [.teal.opacity(0.4), .blue.opacity(0.4), .cyan.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Trail list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, entry in
                        trailRow(entry: entry, index: index)
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
                Text("\(trail.count) site\(trail.count == 1 ? "" : "s") visited")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .padding(.top, 4)
        }
        .liquidGlass(cornerRadius: 14, tint: .teal)
        .shadow(color: .teal.opacity(0.06), radius: 8, y: 4)
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
    private func trailRow(entry: BrowserTrailEntry, index: Int) -> some View {
        let accent = accentColors[index % accentColors.count]

        Button {
            if let url = URL(string: entry.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Accent bar
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    // Page title
                    Text(entry.title.isEmpty ? domainFrom(entry.url) : entry.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Domain badge
                    Text(domainFrom(entry.url))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .textCase(.uppercase)

                    // Summary
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
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

    /// Extract domain from a URL string for display.
    private func domainFrom(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString
        }
        // Strip "www." prefix for cleaner display
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func scheduleAutoDismiss() {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !isHovering else { return }
            await MainActor.run { onDismiss() }
        }
    }
}
