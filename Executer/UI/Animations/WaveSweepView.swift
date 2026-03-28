import SwiftUI

/// A sweeping wave animation that reveals text progressively — like Apple's spatial photo effect.
/// Used when the AI reads and summarizes a Safari/Chrome page.
struct WaveSweepView: View {
    let text: String
    let duration: Double

    @State private var progress: CGFloat = 0
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Background shimmer wave
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, progress - 0.15)),
                        .init(color: Color.purple.opacity(0.3), location: max(0, progress - 0.05)),
                        .init(color: Color.blue.opacity(0.5), location: progress),
                        .init(color: Color.cyan.opacity(0.3), location: min(1, progress + 0.05)),
                        .init(color: .clear, location: min(1, progress + 0.15)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blur(radius: 8)
                .frame(width: geo.size.width, height: geo.size.height)
            }

            // Progressively revealed text
            Text(revealedText)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: revealedText)
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            withAnimation(.easeInOut(duration: duration)) {
                progress = 1.0
            }
        }
    }

    /// Reveals text characters proportionally to the sweep progress.
    private var revealedText: String {
        let count = text.count
        let revealed = Int(Double(count) * Double(progress))
        return String(text.prefix(revealed))
    }
}
