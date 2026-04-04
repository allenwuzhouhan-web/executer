import SwiftUI

// MARK: - Liquid Glass Design System (macOS Tahoe 26.0+)
//
// Liquid Glass is reserved for the navigation/control layer floating above content.
// These helpers provide backward compatibility with older macOS versions.
//
// On macOS 26+: native .glassEffect() with lensing, specular highlights, and adaptive behavior.
// On older macOS: .ultraThinMaterial background with rounded corners (existing behavior).

extension View {

    // MARK: - Card Glass

    /// Liquid Glass card — the standard treatment for floating result cards.
    @ViewBuilder
    func liquidGlass(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = {
                if let tint { return Glass.regular.tint(tint.opacity(0.2)) }
                return .regular
            }()
            self
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background { VisualEffectBackground(material: .popover, blendingMode: .behindWindow) }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Interactive Liquid Glass — for buttons, input pills, and tappable elements.
    /// Adds scaling on press, bouncing animation, and shimmer effects on macOS 26+.
    @ViewBuilder
    func liquidGlassInteractive(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = {
                var g = Glass.regular.interactive()
                if let tint { g = g.tint(tint.opacity(0.2)) }
                return g
            }()
            self
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background { VisualEffectBackground(material: .popover, blendingMode: .behindWindow, cornerRadius: cornerRadius) }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Small circular Liquid Glass — for dismiss/close buttons.
    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self
                .clipShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
    }

    // MARK: - Container & Morphing

    /// Wraps content in a GlassEffectContainer on macOS 26+ for shared sampling and morphing.
    /// Multiple glass elements in the same container share one sampling region (better performance)
    /// and can morph between each other during state transitions.
    @ViewBuilder
    func liquidGlassContainer(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let spacing {
                GlassEffectContainer(spacing: spacing) { self }
            } else {
                GlassEffectContainer { self }
            }
        } else {
            self
        }
    }

    /// Assigns a glass effect ID for morphing transitions between elements.
    /// Elements with the same ID morph into each other when conditionally shown/hidden.
    @ViewBuilder
    func liquidGlassID<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Applies materialize transition — glass forms from concentrated light when appearing.
    @ViewBuilder
    func liquidGlassMaterialize() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectTransition(.materialize)
        } else {
            self
        }
    }
}
