import SwiftUI

/// Frosted glass background using SwiftUI's native material — pre-macOS 26 fallback.
struct VisualEffectBackground: View {
    var cornerRadius: CGFloat = 0

    /// Legacy initializer for backward compatibility with existing call sites.
    init(material: NSVisualEffectView.Material = .popover,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
