import SwiftUI

/// An animated rainbow gradient shimmer — Apple Intelligence style.
struct ShimmerView: View {
    var animationSpeed: Double = 1.0

    @State private var phase: CGFloat = -1.0

    private let colors: [Color] = [
        .clear,
        Color(hue: 0.75, saturation: 0.25, brightness: 1.0).opacity(0.5),  // Purple
        Color(hue: 0.60, saturation: 0.25, brightness: 1.0).opacity(0.5),  // Blue
        Color(hue: 0.85, saturation: 0.25, brightness: 1.0).opacity(0.5),  // Pink
        Color(hue: 0.08, saturation: 0.25, brightness: 1.0).opacity(0.5),  // Orange
        .clear
    ]

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: colors,
                startPoint: UnitPoint(x: phase, y: 0.5),
                endPoint: UnitPoint(x: phase + 0.6, y: 0.5)
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            let duration = max(0.5, 2.5 / animationSpeed)
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }
}
