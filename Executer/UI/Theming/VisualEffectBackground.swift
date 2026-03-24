import SwiftUI

/// Frosted glass background using SwiftUI's native material — no NSVisualEffectView border artifacts.
struct VisualEffectBackground: View {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
