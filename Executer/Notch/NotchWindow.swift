import Cocoa

/// A small clickable window positioned over the notch area.
class NotchWindow: NSPanel {
    var onClick: (() -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    private var blackView: NotchShapeView!
    private var glowView: NotchGlowView!
    private var isHovered = false
    private var learningDot: LearningDotView!
    private var isDragHovered = false
    private var originalFrame: CGRect = .zero
    private let filletRadius: CGFloat = 6

    init(onClick: (() -> Void)? = nil) {
        self.onClick = onClick

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 250, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Use popUpMenu level instead of CGShieldingWindowLevel — shielding level is
        // above the system drag layer, which blocks all drag & drop operations.
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false

        blackView = NotchShapeView(frame: .zero)
        blackView.alphaValue = 0

        glowView = NotchGlowView(frame: .zero)
        glowView.alphaValue = 0

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.clear
        container.autoresizingMask = [.width, .height]
        container.registerForDraggedTypes([.fileURL])
        blackView.autoresizingMask = [.width, .height]
        glowView.autoresizingMask = [.width, .height]
        container.addSubview(glowView)
        container.addSubview(blackView)

        let clickView = NotchClickView(frame: .zero)
        clickView.onClick = { [weak self] in self?.onClick?() }
        clickView.onHoverChanged = { [weak self] hovering in self?.setHoverState(hovering) }
        clickView.onDragHoverChanged = { [weak self] hovering in self?.setDragHoverState(hovering) }
        clickView.onFilesDrop = { [weak self] urls in self?.onFileDrop?(urls) }
        clickView.autoresizingMask = [.width, .height]
        container.addSubview(clickView)

        contentView = container

        // Learning indicator: small teal pulsing dot at bottom-center of notch
        learningDot = LearningDotView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))
        learningDot.alphaValue = 0
        container.addSubview(learningDot)

        // Observe learning state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(learningStateChanged(_:)),
            name: .learningStateChanged,
            object: nil
        )

        updateFrame()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func updateFrame() {
        guard let notchRect = ScreenGeometry.notchRect() else {
            orderOut(nil)
            return
        }
        setFrame(notchRect, display: true)

        // Center learning dot at bottom of notch
        let dotSize: CGFloat = 6
        learningDot.frame = CGRect(
            x: (notchRect.width - dotSize) / 2,
            y: 4,
            width: dotSize,
            height: dotSize
        )

        if !isHovered {
            originalFrame = notchRect
        }
    }

    private func setHoverState(_ hovering: Bool) {
        guard hovering != isHovered else { return }
        isHovered = hovering

        if hovering {
            // Expand: sides by 5px, down by 5px, extra width for fillet ears
            let expand: CGFloat = 5
            let fr = filletRadius
            let expanded = CGRect(
                x: originalFrame.origin.x - expand - fr,
                y: originalFrame.origin.y - expand,
                width: originalFrame.width + (expand + fr) * 2,
                height: originalFrame.height + expand
            )

            blackView.alphaValue = 1

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(expanded, display: true)
            }
        } else {
            // Shrink first, THEN fade black — never show transparent expanded notch
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(originalFrame, display: true)
            } completionHandler: { [weak self] in
                self?.blackView.alphaValue = 0
            }
        }
    }

    private func setDragHoverState(_ hovering: Bool) {
        guard hovering != isDragHovered else { return }
        isDragHovered = hovering

        if hovering {
            // Expand notch and show rainbow glow silhouette
            let expand: CGFloat = 8
            let fr = filletRadius
            let expanded = CGRect(
                x: originalFrame.origin.x - expand - fr,
                y: originalFrame.origin.y - expand,
                width: originalFrame.width + (expand + fr) * 2,
                height: originalFrame.height + expand
            )

            blackView.alphaValue = 1
            glowView.alphaValue = 1
            glowView.startPulsing()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(expanded, display: true)
            }
        } else {
            glowView.stopPulsing()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(originalFrame, display: true)
                blackView.animator().alphaValue = 0
                glowView.animator().alphaValue = 0
            }
        }
    }

    @objc private func screenDidChange(_ notification: Notification) {
        updateFrame()
    }

    @objc private func learningStateChanged(_ notification: Notification) {
        let isLearning = notification.userInfo?["isLearning"] as? Bool ?? false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            learningDot.animator().alphaValue = isLearning ? 1.0 : 0.0
        }
    }

    override var canBecomeKey: Bool { false }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Custom notch shape: flat top, concave fillets at top corners, rounded bottom corners

class NotchShapeView: NSView {
    private let bottomRadius: CGFloat = 14
    private let filletRadius: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateShapeMask()
    }

    private func updateShapeMask() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let cr = min(bottomRadius, h / 2, (w - filletRadius * 2) / 2)
        let fr = filletRadius

        // The body (main rectangle) is inset from each side by the fillet radius.
        // The fillets at the top extend to the full view width.
        let bodyLeft = fr
        let bodyRight = w - fr

        let path = CGMutablePath()

        // Start at bottom-left of body, above the corner
        path.move(to: CGPoint(x: bodyLeft, y: cr))

        // Bottom-left convex rounded corner
        path.addArc(
            center: CGPoint(x: bodyLeft + cr, y: cr),
            radius: cr, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: bodyRight - cr, y: 0))

        // Bottom-right convex rounded corner
        path.addArc(
            center: CGPoint(x: bodyRight - cr, y: cr),
            radius: cr, startAngle: 3 * .pi / 2, endAngle: 0, clockwise: false
        )

        // Right side going up to where the fillet starts
        path.addLine(to: CGPoint(x: bodyRight, y: h - fr))

        // Top-right concave fillet (outward ear)
        // Curves from (bodyRight, h - fr) outward to (w, h)
        path.addArc(
            center: CGPoint(x: w, y: h - fr),
            radius: fr, startAngle: .pi, endAngle: .pi / 2, clockwise: true
        )

        // Top edge (flush with screen top)
        path.addLine(to: CGPoint(x: 0, y: h))

        // Top-left concave fillet (outward ear)
        // Curves from (0, h) inward to (bodyLeft, h - fr)
        path.addArc(
            center: CGPoint(x: 0, y: h - fr),
            radius: fr, startAngle: .pi / 2, endAngle: 0, clockwise: true
        )

        // Left side going down
        path.addLine(to: CGPoint(x: bodyLeft, y: cr))

        path.closeSubpath()

        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
    }
}

// MARK: - Click/hover capture view

class NotchClickView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragHoverChanged: ((Bool) -> Void)?
    var onFilesDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasFileURLs(sender) {
            onDragHoverChanged?(true)
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return hasFileURLs(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHoverChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHoverChanged?(false)

        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        onFilesDrop?(urls)
        return true
    }

    private func hasFileURLs(_ info: NSDraggingInfo) -> Bool {
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])
    }
}

// MARK: - Rainbow glow silhouette for drag hover

class NotchGlowView: NSView {
    private let glowLayer = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Soft pastel rainbow — Apple Intelligence style, not neon
        glowLayer.type = .axial
        glowLayer.startPoint = CGPoint(x: 0, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        glowLayer.colors = [
            NSColor(hue: 0.75, saturation: 0.30, brightness: 1.0, alpha: 0.6).cgColor,  // Soft purple
            NSColor(hue: 0.58, saturation: 0.35, brightness: 1.0, alpha: 0.6).cgColor,  // Soft blue
            NSColor(hue: 0.48, saturation: 0.30, brightness: 1.0, alpha: 0.6).cgColor,  // Soft cyan
            NSColor(hue: 0.85, saturation: 0.25, brightness: 1.0, alpha: 0.6).cgColor,  // Soft pink
            NSColor(hue: 0.08, saturation: 0.25, brightness: 1.0, alpha: 0.6).cgColor,  // Soft orange
        ]
        glowLayer.cornerRadius = 10
        layer?.addSublayer(glowLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds.insetBy(dx: -2, dy: -2)

        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: glowLayer.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        glowLayer.mask = mask

        glowLayer.shadowColor = NSColor(hue: 0.60, saturation: 0.3, brightness: 1.0, alpha: 1.0).cgColor
        glowLayer.shadowRadius = 8
        glowLayer.shadowOpacity = 0.5
        glowLayer.shadowOffset = .zero
    }

    func startPulsing() {
        // Gentle opacity pulse
        let opacityPulse = CABasicAnimation(keyPath: "opacity")
        opacityPulse.fromValue = 0.6
        opacityPulse.toValue = 1.0
        opacityPulse.duration = 1.0
        opacityPulse.autoreverses = true
        opacityPulse.repeatCount = .infinity
        opacityPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(opacityPulse, forKey: "pulse")

        // Slow color shift — the gradient colors rotate
        let colorShift = CABasicAnimation(keyPath: "colors")
        colorShift.toValue = [
            NSColor(hue: 0.08, saturation: 0.25, brightness: 1.0, alpha: 0.6).cgColor,
            NSColor(hue: 0.75, saturation: 0.30, brightness: 1.0, alpha: 0.6).cgColor,
            NSColor(hue: 0.58, saturation: 0.35, brightness: 1.0, alpha: 0.6).cgColor,
            NSColor(hue: 0.48, saturation: 0.30, brightness: 1.0, alpha: 0.6).cgColor,
            NSColor(hue: 0.85, saturation: 0.25, brightness: 1.0, alpha: 0.6).cgColor,
        ]
        colorShift.duration = 2.0
        colorShift.autoreverses = true
        colorShift.repeatCount = .infinity
        colorShift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(colorShift, forKey: "colorShift")
    }

    func stopPulsing() {
        glowLayer.removeAllAnimations()
    }
}

// MARK: - Learning indicator dot

class LearningDotView: NSView {
    private let dotLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dotLayer.backgroundColor = NSColor(hue: 0.52, saturation: 0.4, brightness: 1.0, alpha: 0.8).cgColor
        dotLayer.cornerRadius = 3
        dotLayer.shadowColor = NSColor(hue: 0.52, saturation: 0.5, brightness: 1.0, alpha: 1.0).cgColor
        dotLayer.shadowRadius = 4
        dotLayer.shadowOpacity = 0.6
        dotLayer.shadowOffset = .zero
        layer?.addSublayer(dotLayer)

        // Gentle pulse
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.5, 1.0, 0.5]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 3.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        dotLayer.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dotLayer.frame = bounds
    }
}
