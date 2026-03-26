import Cocoa
import QuartzCore

/// Singleton full-screen glow overlay shown while agents are working.
/// Reuses the window across invocations; only the glow layer is recreated per show.
class AgentGlowWindow {
    static let shared = AgentGlowWindow()

    private var window: NSWindow?
    private var glowLayer: AgentGlowLayer?
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
        let glow = AgentGlowLayer()
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

// MARK: - AgentGlowLayer

/// Subtle rainbow edge glow with rounded corners matching Mac display.
class AgentGlowLayer: CALayer {

    private let edgeDepth: CGFloat = 50
    private let screenCornerRadius: CGFloat = 10.0
    private var edgeLayers: [CAGradientLayer] = []
    private var colorTimer: Timer?
    private var colorPhase: Int = 0

    private let rainbowColors: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.55, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.08, saturation: 0.55, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.15, saturation: 0.45, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.33, saturation: 0.45, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.55, saturation: 0.45, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.62, saturation: 0.55, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.75, saturation: 0.45, brightness: 1.0, alpha: 0.40).cgColor,
        NSColor(hue: 0.85, saturation: 0.40, brightness: 1.0, alpha: 0.40).cgColor,
    ]

    private let rainbowShadows: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.08, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.15, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.33, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.55, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.62, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.75, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.85, saturation: 0.5, brightness: 1.0, alpha: 1.0).cgColor,
    ]

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let transparent = CGColor.clear

        let edges: [(CGRect, CGPoint, CGPoint, Int)] = [
            (CGRect(x: 0, y: h - edgeDepth, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), 0),
            (CGRect(x: w - edgeDepth, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5), 2),
            (CGRect(x: 0, y: 0, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), 4),
            (CGRect(x: 0, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), 6),
        ]

        for (frame, start, end, colorOffset) in edges {
            let gradient = CAGradientLayer()
            gradient.frame = frame
            let idx = colorOffset % rainbowColors.count
            gradient.colors = [rainbowColors[idx], transparent]
            gradient.startPoint = start
            gradient.endPoint = end
            gradient.locations = [0.0, 1.0]
            gradient.shadowColor = rainbowShadows[idx]
            gradient.shadowRadius = 20
            gradient.shadowOpacity = 0.4
            gradient.shadowOffset = .zero
            addSublayer(gradient)
            edgeLayers.append(gradient)
        }

        // Rounded corner mask matching Mac display
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(roundedRect: bounds, cornerWidth: screenCornerRadius,
                                cornerHeight: screenCornerRadius, transform: nil)
        mask = maskLayer

        opacity = 0

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.5
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        add(fadeIn, forKey: "fadeIn")

        // Slow breathing pulse — calmer than voice glow
        for edge in edgeLayers {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.25, 0.5, 0.25]
            pulse.keyTimes = [0, 0.5, 1.0]
            pulse.duration = 4.0
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.repeatCount = .infinity
            edge.add(pulse, forKey: "breathing")
        }

        // Rainbow color rotation
        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self = self, !self.edgeLayers.isEmpty else {
                timer.invalidate()
                return
            }
            self.colorPhase = (self.colorPhase + 1) % self.rainbowColors.count

            for (i, edge) in self.edgeLayers.enumerated() {
                let idx = (self.colorPhase + i * 2) % self.rainbowColors.count

                let colorAnim = CABasicAnimation(keyPath: "colors")
                colorAnim.toValue = [self.rainbowColors[idx], CGColor.clear]
                colorAnim.duration = 0.4
                colorAnim.fillMode = .forwards
                colorAnim.isRemovedOnCompletion = false
                edge.add(colorAnim, forKey: "rainbow")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = self.rainbowShadows[idx]
                shadowAnim.duration = 0.4
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                edge.add(shadowAnim, forKey: "rainbowShadow")
            }
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        colorTimer?.invalidate()
        colorTimer = nil

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.toValue = 0
        fadeOut.duration = 0.6
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        add(fadeOut, forKey: "fadeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completion()
        }
    }
}
