import Cocoa
import QuartzCore

/// Rainbow AI glow around the screen edges on launch — colors sweep around the border.
class LaunchGlowLayer: CALayer {

    private var borderLayers: [CAShapeLayer] = []
    private var colorTimer: Timer?

    // Rainbow AI spectrum — vibrant but not harsh
    private let rainbowColors: [NSColor] = [
        NSColor(hue: 0.00, saturation: 0.7, brightness: 1.0, alpha: 0.7), // Red
        NSColor(hue: 0.08, saturation: 0.7, brightness: 1.0, alpha: 0.7), // Orange
        NSColor(hue: 0.15, saturation: 0.6, brightness: 1.0, alpha: 0.7), // Yellow
        NSColor(hue: 0.33, saturation: 0.6, brightness: 1.0, alpha: 0.7), // Green
        NSColor(hue: 0.55, saturation: 0.6, brightness: 1.0, alpha: 0.7), // Cyan
        NSColor(hue: 0.62, saturation: 0.7, brightness: 1.0, alpha: 0.7), // Blue
        NSColor(hue: 0.75, saturation: 0.6, brightness: 1.0, alpha: 0.7), // Purple
        NSColor(hue: 0.85, saturation: 0.5, brightness: 1.0, alpha: 0.7), // Pink
    ]

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        // Create multiple border layers, each offset in color for the rainbow sweep
        let layerCount = 4
        let path = CGPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)

        for i in 0..<layerCount {
            let border = CAShapeLayer()
            border.path = path
            border.fillColor = nil
            let colorIndex = (i * 2) % rainbowColors.count
            let color = rainbowColors[colorIndex]
            border.strokeColor = color.cgColor
            border.lineWidth = CGFloat(6 - i)
            border.shadowColor = color.cgColor
            border.shadowRadius = CGFloat(20 - i * 3)
            border.shadowOpacity = Float(0.9 - Double(i) * 0.15)
            border.shadowOffset = .zero
            border.opacity = 0
            addSublayer(border)
            borderLayers.append(border)

            // Stagger fade-in for each layer
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.4
            fadeIn.beginTime = CACurrentMediaTime() + Double(i) * 0.08
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            border.add(fadeIn, forKey: "fadeIn")
        }

        // Animate rainbow color sweep
        var phase = 0
        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self = self, !self.borderLayers.isEmpty else {
                timer.invalidate()
                return
            }
            phase += 1
            for (i, border) in self.borderLayers.enumerated() {
                let colorIndex = (phase + i * 2) % self.rainbowColors.count
                let color = self.rainbowColors[colorIndex]

                let colorAnim = CABasicAnimation(keyPath: "strokeColor")
                colorAnim.toValue = color.cgColor
                colorAnim.duration = 0.15
                colorAnim.fillMode = .forwards
                colorAnim.isRemovedOnCompletion = false
                border.add(colorAnim, forKey: "colorSweep")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = color.cgColor
                shadowAnim.duration = 0.15
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                border.add(shadowAnim, forKey: "shadowSweep")
            }
        }

        // Breathing pulse on the main glow
        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.6, 1.0, 0.6, 1.0, 0.6]
        pulse.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        pulse.duration = 2.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayers.first?.add(pulse, forKey: "pulse")

        // Fade out after the rainbow sweep
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.colorTimer?.invalidate()
            self?.colorTimer = nil

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.toValue = 0
            fadeOut.duration = 0.8
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            self?.add(fadeOut, forKey: "fadeOut")
        }
    }
}
