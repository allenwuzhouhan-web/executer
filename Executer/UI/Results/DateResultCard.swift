import SwiftUI
import EventKit
import AppKit

/// Rich card for date responses — shows formatted date with "Add to Calendar" action.
struct DateResultCard: View {
    let result: DateResult
    let rawMessage: String
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var addedToCalendar = false
    @State private var showCopied = false
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var isHovering = false

    private let accentGradient = LinearGradient(
        colors: [.blue, .teal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentGradient)

                Text("Date")
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

            // Date display
            VStack(alignment: .leading, spacing: 4) {
                Text(result.formattedDate)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(result.relativeDescription)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let context = result.context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            // Divider
            Rectangle()
                .fill(accentGradient.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Actions
            HStack(spacing: 12) {
                Button {
                    addToCalendar()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                        Text(addedToCalendar ? "Added" : "Add to Calendar")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(addedToCalendar ? .green : .blue)
                }
                .buttonStyle(.plain)
                .disabled(addedToCalendar)

                Button {
                    copyDate()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(showCopied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(showCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .liquidGlass(cornerRadius: 14, tint: .blue)
        .shadow(color: .blue.opacity(0.06), radius: 8, y: 4)
        .padding(.top, 6)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appeared)
        .onAppear {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            withAnimation { appeared = true }
            scheduleAutoDismiss()
        }
        .onHover { isHovering = $0 }
        .onDisappear { autoDismissTask?.cancel() }
    }

    private func addToCalendar() {
        let store = EKEventStore()
        store.requestFullAccessToEvents { granted, _ in
            guard granted else { return }
            let event = EKEvent(eventStore: store)
            event.title = result.context ?? "Event"
            event.startDate = result.date
            event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: result.date)
            event.calendar = store.defaultCalendarForNewEvents
            try? store.save(event, span: .thisEvent)
            DispatchQueue.main.async { addedToCalendar = true }
        }
    }

    private func copyDate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.formattedDate, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !isHovering else { return }
            await MainActor.run { onDismiss() }
        }
    }
}
