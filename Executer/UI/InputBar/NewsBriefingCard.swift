import SwiftUI
import AppKit

/// A beautiful news briefing card that slides in with headlines and gradient accents.
struct NewsBriefingCard: View {
    let articles: [NewsBriefingArticle]
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var hoveredIndex: Int? = nil
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var isHovering = false

    // Gradient colors for each headline row — cycles through a curated palette
    private let accentColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo
    ]

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("\(greeting) — here's your briefing")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    onDismiss()
                } label: {
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

            // Divider with gradient
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

            // Headlines
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(articles.enumerated()), id: \.offset) { index, article in
                        headlineRow(article: article, index: index)
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
            .frame(maxHeight: 220)

            // Footer
            HStack {
                Text("Powered by NewsAPI")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
                Spacer()
                Text(timeString)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .padding(.top, 4)
        }
        .background {
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .blue.opacity(0.3),
                            .purple.opacity(0.2),
                            .orange.opacity(0.15),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .blue.opacity(0.08), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(.top, 6)
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            withAnimation { appeared = true }
            scheduleAutoDismiss()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    // MARK: - Headline Row

    @ViewBuilder
    private func headlineRow(article: NewsBriefingArticle, index: Int) -> some View {
        let accent = accentColors[index % accentColors.count]

        Button {
            openURL(article.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Colored accent bar
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 3) {
                    // Source tag
                    Text(article.source.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(accent.opacity(0.8))
                        .tracking(0.5)

                    // Title
                    Text(article.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Description snippet
                    if let desc = article.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Open indicator on hover
                if hoveredIndex == index {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if hoveredIndex == index {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredIndex = hovering ? index : nil
            }
        }
    }

    // MARK: - Helpers

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date())
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            guard !Task.isCancelled, !isHovering else { return }
            await MainActor.run { onDismiss() }
        }
    }
}
