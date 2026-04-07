import SwiftUI

/// Full execution trace card — shows everything the agent did during a task.
/// Modeled after TrainerResultCard with expandable sections.
struct AgentTraceCard: View {
    let trace: AgentTrace
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var expandedSection: String?
    @State private var expandedEntryId: UUID?

    private var isFailed: Bool {
        if case .failure = trace.finalOutcome { return true }
        return false
    }

    private var outcomeBadge: (String, Color) {
        switch trace.finalOutcome {
        case .success: return ("Success", .green)
        case .failure: return ("Failed", .red)
        case .cancelled: return ("Cancelled", .orange)
        case .none: return ("Unknown", .gray)
        }
    }

    private var accentColor: Color { isFailed ? .red : .blue }

    private var toolCallEntries: [TraceEntry] {
        trace.entries.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }
    }

    private var errorEntries: [TraceEntry] {
        trace.errorEntries
    }

    private var hasReasoning: Bool {
        trace.entries.contains {
            if case .llmCall(_, _, _, let r) = $0.kind { return r != nil }
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            dividerBar
            scrollContent
            footer
        }
        .liquidGlass(cornerRadius: 14, tint: accentColor)
        .shadow(color: accentColor.opacity(0.06), radius: 8, y: 4)
        .padding(.top, 6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "eye.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentColor)

            Text("Execution Trace")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            let (label, color) = outcomeBadge
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .clipShape(Capsule())

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
        .padding(.bottom, 4)
    }

    private var dividerBar: some View {
        Rectangle()
            .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.3)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                summarySection
                if trace.planOutput != nil { planSection }
                if !toolCallEntries.isEmpty { toolCallsSection }
                if hasReasoning { reasoningSection }
                if !errorEntries.isEmpty { errorsSection }
                timelineSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 350)
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trace.goal)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                statBadge(icon: "clock", value: trace.formattedDuration)
                statBadge(icon: "wrench", value: "\(trace.toolCallCount) tools")
                statBadge(icon: "brain", value: "\(trace.llmCallCount) LLM calls")
                if !trace.errorEntries.isEmpty {
                    statBadge(icon: "xmark.circle", value: "\(trace.errorEntries.count) errors", color: .red)
                }
            }
            .padding(.top, 2)
        }
    }

    private func statBadge(icon: String, value: String, color: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .rounded))
        }
        .foregroundStyle(color)
    }

    // MARK: - Plan

    private var planSection: some View {
        Group {
            sectionHeader("Plan", icon: "list.number", color: .teal)
            if isSectionExpanded("Plan"), let plan = trace.planOutput {
                Text(plan)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Tool Calls

    private var toolCallsSection: some View {
        Group {
            sectionHeader("Tool Calls (\(toolCallEntries.count))", icon: "wrench.and.screwdriver", color: .blue)
            if isSectionExpanded("Tool Calls (\(toolCallEntries.count))") {
                ForEach(Array(toolCallEntries.enumerated()), id: \.element.id) { i, entry in
                    if case .toolCall(let name, let args, let result, let ms, let success) = entry.kind {
                        toolCallRow(name: name, arguments: args, result: result, durationMs: ms, success: success, entryId: entry.id)
                            .opacity(appeared ? 1 : 0)
                            .animation(.easeOut.delay(Double(i) * 0.02), value: appeared)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toolCallRow(name: String, arguments: String, result: String, durationMs: Double, success: Bool, entryId: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedEntryId = expandedEntryId == entryId ? nil : entryId
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(success ? .green : .red)

                    Text(name)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(Int(durationMs))ms")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Image(systemName: expandedEntryId == entryId ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            .padding(.leading, 20)

            if expandedEntryId == entryId {
                VStack(alignment: .leading, spacing: 4) {
                    if !arguments.isEmpty && arguments != "{}" {
                        Text("Arguments:")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                        Text(TraceRedactor.redact(prettyJSON(arguments)))
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("Result:")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(TraceRedactor.redact(String(result.prefix(2000))))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(success ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.red))
                        .textSelection(.enabled)
                        .lineLimit(20)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.leading, 36)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Reasoning

    private var reasoningSection: some View {
        Group {
            sectionHeader("LLM Reasoning", icon: "brain", color: .purple)
            if isSectionExpanded("LLM Reasoning") {
                ForEach(trace.entries.filter {
                    if case .llmCall(_, _, _, let r) = $0.kind { return r != nil }
                    return false
                }) { entry in
                    if case .llmCall(_, _, _, let reasoning) = entry.kind, let r = reasoning {
                        Text(TraceRedactor.redact(String(r.prefix(1000))))
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 20)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Errors

    private var errorsSection: some View {
        Group {
            sectionHeader("Errors (\(errorEntries.count))", icon: "exclamationmark.triangle.fill", color: .red)
            if isSectionExpanded("Errors (\(errorEntries.count))") {
                ForEach(errorEntries) { entry in
                    if case .error(let source, let message) = entry.kind {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.red)
                                Text(message)
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 20)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        Group {
            sectionHeader("Full Timeline (\(trace.entries.count) events)", icon: "clock.arrow.circlepath", color: .secondary)
            if isSectionExpanded("Full Timeline (\(trace.entries.count) events)") {
                ForEach(Array(trace.entries.enumerated()), id: \.element.id) { i, entry in
                    TraceTimelineRow(entry: entry, traceStart: trace.startTime)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut.delay(Double(i) * 0.015), value: appeared)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(trace.entries.count) events")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(trace.formattedDuration)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Section Header (TrainerResultCard pattern)

    private func isSectionExpanded(_ title: String) -> Bool {
        expandedSection == nil || expandedSection == title
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                if expandedSection == title {
                    expandedSection = nil
                } else {
                    expandedSection = title
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSectionExpanded(title) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }
}
