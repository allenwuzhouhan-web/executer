import Cocoa
import QuartzCore

/// Subtle top-edge glow indicating the Learning system is actively observing.
/// Shows a faint teal halo emanating from the notch area — visible enough to notice,
/// subtle enough to not distract. Follows the AgentGlowWindow pattern exactly.
class LearningGlowWindow {
    static let shared = LearningGlowWindow()

    private var window: NSWindow?
    private var glowLayer: LearningGlowLayer?
    private var isShowing = false

    func show() {
        guard !isShowing else { return }
        isShowing = true

        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }

        if window == nil {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.isReleasedWhenClosed = false

            let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            container.layer?.backgroundColor = CGColor.clear
            win.contentView = container
            window = win
        }

        glowLayer?.removeFromSuperlayer()
        let glow = LearningGlowLayer()
        glow.frame = window!.contentView!.bounds
        glow.contentsScale = screen.backingScaleFactor
        window!.contentView!.layer?.addSublayer(glow)
        glowLayer = glow

        window?.orderFrontRegardless()
        DispatchQueue.main.async { glow.startAnimation() }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        glowLayer?.fadeOut { [weak self] in
            self?.window?.orderOut(nil)
            self?.glowLayer?.removeFromSuperlayer()
            self?.glowLayer = nil
        }
    }
}

// MARK: - LearningGlowLayer

/// Top-edge-only teal glow with very slow breathing pulse.
/// Much subtler than AgentGlowLayer — a whisper, not a statement.
class LearningGlowLayer: CALayer {

    private let edgeDepth: CGFloat = 30       // Thinner than agent's 50
    private let screenCornerRadius: CGFloat = 10.0
    private var topEdgeLayer: CAGradientLayer?
    private var pulseTimer: Timer?

    // Teal/cyan palette — distinct from agent rainbow and voice purple
    private let tealColor = NSColor(hue: 0.52, saturation: 0.35, brightness: 1.0, alpha: 0.15).cgColor
    private let tealShadow = NSColor(hue: 0.52, saturation: 0.5, brightness: 1.0, alpha: 1.0).cgColor

    // Secondary color for subtle shift
    private let cyanColor = NSColor(hue: 0.48, saturation: 0.30, brightness: 1.0, alpha: 0.12).cgColor
    private let cyanShadow = NSColor(hue: 0.48, saturation: 0.45, brightness: 1.0, alpha: 1.0).cgColor

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        // Only the top edge — a halo emanating from the notch
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: h - edgeDepth, width: w, height: edgeDepth)
        gradient.colors = [tealColor, CGColor.clear]
        gradient.startPoint = CGPoint(x: 0.5, y: 0) // Color at top
        gradient.endPoint = CGPoint(x: 0.5, y: 1)   // Fades downward
        gradient.locations = [0.0, 1.0]
        gradient.shadowColor = tealShadow
        gradient.shadowRadius = 12
        gradient.shadowOpacity = 0.15
        gradient.shadowOffset = .zero
        addSublayer(gradient)
        topEdgeLayer = gradient

        // Rounded corner mask
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(roundedRect: bounds, cornerWidth: screenCornerRadius,
                                cornerHeight: screenCornerRadius, transform: nil)
        mask = maskLayer

        // Fade in
        opacity = 0
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 1.0 // Slower fade-in than agent
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        add(fadeIn, forKey: "fadeIn")

        // Very slow breathing — 8 second cycle (vs agent's 4)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.6, 1.0, 0.6]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 8.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        gradient.add(pulse, forKey: "breathing")

        // Very slow color shift between teal and cyan
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] timer in
            guard let self = self, let edge = self.topEdgeLayer else {
                timer.invalidate()
                return
            }

            // Alternate between teal and cyan
            let useAlt = (Int(Date().timeIntervalSinceReferenceDate) / 4) % 2 == 0
            let targetColor = useAlt ? self.cyanColor : self.tealColor
            let targetShadow = useAlt ? self.cyanShadow : self.tealShadow

            let colorAnim = CABasicAnimation(keyPath: "colors")
            colorAnim.toValue = [targetColor, CGColor.clear]
            colorAnim.duration = 3.0
            colorAnim.fillMode = .forwards
            colorAnim.isRemovedOnCompletion = false
            edge.add(colorAnim, forKey: "colorShift")

            let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
            shadowAnim.toValue = targetShadow
            shadowAnim.duration = 3.0
            shadowAnim.fillMode = .forwards
            shadowAnim.isRemovedOnCompletion = false
            edge.add(shadowAnim, forKey: "shadowShift")
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.toValue = 0
        fadeOut.duration = 0.8
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        add(fadeOut, forKey: "fadeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            completion()
        }
    }
}
