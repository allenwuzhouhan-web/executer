import SwiftUI

/// Single row in the agent trace timeline — colored dot, time offset, summary.
struct TraceTimelineRow: View {
    let entry: TraceEntry
    let traceStart: Date

    private var offsetText: String {
        let seconds = entry.timestamp.timeIntervalSince(traceStart)
        if seconds < 1 { return "+0.0s" }
        if seconds < 60 { return String(format: "+%.1fs", seconds) }
        return String(format: "+%.0fm%.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }

    private var dotColor: Color {
        switch entry.colorName {
        case "purple": return .purple
        case "blue": return .blue
        case "red": return .red
        case "teal": return .teal
        case "orange": return .orange
        case "gray": return .gray
        case "yellow": return .yellow
        case "green": return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(offsetText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)

            Text(entry.summary)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let ms = entry.durationMs {
                Spacer()
                Text("\(Int(ms))ms")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
