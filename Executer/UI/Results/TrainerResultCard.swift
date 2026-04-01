import SwiftUI
import AppKit

/// Rich card showing full document training results — all 8 stages of analysis.
struct TrainerResultCard: View {
    let profile: DocumentStudyProfile
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var showCopied = false
    @State private var isHovering = false
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var expandedSection: String?

    private var qualityColor: Color {
        if profile.qualityScore >= 0.7 { return .green }
        if profile.qualityScore >= 0.4 { return .orange }
        return .red
    }

    private let accentGradient = LinearGradient(
        colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentGradient)

                Text(profile.sourceFile)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(profile.qualityScore * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(qualityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(qualityColor.opacity(0.15))
                    .clipShape(Capsule())

                Button { copyAll() } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(showCopied ? .green : .secondary)
                        .frame(width: 18, height: 18)
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
            .padding(.bottom, 4)

            // One-liner + meta
            Text(profile.summary.oneLiner)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)

            HStack(spacing: 8) {
                tag(profile.content.domain)
                tag(profile.content.audienceLevel)
                tag("\(profile.structure.totalSections) slides")
                tag(profile.content.teachingApproach)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            Rectangle().fill(accentGradient.opacity(0.3)).frame(height: 1).padding(.horizontal, 12)

            // Scrollable full analysis
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {

                    // Key Takeaways
                    if !profile.summary.bullets.isEmpty {
                        sectionHeader("Key Points", icon: "list.bullet.circle.fill", color: .blue)
                        ForEach(Array(profile.summary.bullets.enumerated()), id: \.offset) { i, bullet in
                            bulletRow(bullet)
                                .opacity(appeared ? 1 : 0)
                                .animation(.easeOut.delay(Double(i) * 0.03), value: appeared)
                        }
                    }

                    // Design Rules
                    if !profile.style.formattingPatterns.isEmpty {
                        sectionHeader("Design Rules", icon: "paintpalette.fill", color: .purple)
                        ForEach(profile.style.formattingPatterns, id: \.self) { rule in
                            ruleRow(rule, color: .purple)
                        }
                    }

                    // Key Terms
                    if !profile.content.keyTerms.isEmpty {
                        sectionHeader("Key Terms", icon: "text.book.closed.fill", color: .teal)
                        ForEach(Array(profile.content.keyTerms.enumerated()), id: \.offset) { _, term in
                            termRow(term)
                        }
                    }

                    // Quality Notes
                    if let notes = profile.qualityNotes, !notes.isEmpty {
                        sectionHeader("Quality Assessment", icon: "checkmark.shield.fill", color: qualityColor)
                        Text(notes)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    // Study Recommendation
                    if !profile.summary.studyRecommendation.isEmpty {
                        sectionHeader("Study Recommendation", icon: "lightbulb.fill", color: .yellow)
                        Text(profile.summary.studyRecommendation)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)
        }
        .background { VisualEffectBackground(material: .popover, blendingMode: .behindWindow) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentGradient.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .purple.opacity(0.08), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(.top, 6)
        .onHover { isHovering = $0 }
        .onAppear {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            withAnimation { appeared = true }
        }
        .onDisappear { autoDismissTask?.cancel() }
    }

    // MARK: - Components

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func bulletRow(_ bullet: LeveledBullet) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(importanceColor(bullet.importance))
                .frame(width: 4, height: 4)
                .padding(.top, 5)

            Text(bullet.text)
                .font(.system(size: 10, weight: bullet.importance == "critical" ? .semibold : .regular, design: .rounded))
                .foregroundStyle(bullet.importance == "critical" ? .primary : .secondary)
        }
        .padding(.leading, CGFloat(bullet.level) * 12 + 8)
    }

    @ViewBuilder
    private func ruleRow(_ rule: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(color.opacity(0.6))
                .padding(.top, 4)
            Text(rule)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func termRow(_ term: KeyTerm) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(term.term)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.teal)
            if let def = term.definition, !def.isEmpty {
                Text(def)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())
    }

    private func importanceColor(_ importance: String) -> Color {
        switch importance {
        case "critical": return .red
        case "important": return .orange
        default: return .gray
        }
    }

    private func copyAll() {
        var text = "# \(profile.sourceFile) — Training Analysis\n\n"
        text += "Quality: \(Int(profile.qualityScore * 100))% | \(profile.content.domain) | \(profile.content.audienceLevel)\n\n"
        text += "## Summary\n\(profile.summary.oneLiner)\n\n"

        text += "## Key Points\n"
        for b in profile.summary.bullets {
            text += "\(String(repeating: "  ", count: b.level))- \(b.text)\n"
        }

        if !profile.style.formattingPatterns.isEmpty {
            text += "\n## Design Rules\n"
            for r in profile.style.formattingPatterns { text += "- \(r)\n" }
        }

        if !profile.content.keyTerms.isEmpty {
            text += "\n## Key Terms\n"
            for t in profile.content.keyTerms { text += "- **\(t.term)**: \(t.definition ?? "")\n" }
        }

        if let notes = profile.qualityNotes { text += "\n## Quality\n\(notes)\n" }
        text += "\n## Study Recommendation\n\(profile.summary.studyRecommendation)"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
    }
}
