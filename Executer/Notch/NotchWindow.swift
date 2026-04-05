import Cocoa

/// A small clickable window positioned over the notch area.
class NotchWindow: NSPanel {
    var onClick: (() -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    private var blackView: NotchShapeView!
    private var glowView: NotchGlowView!
    private var isHovered = false
    private var learningDot: LearningDotView!
    private var suggestionDot: SuggestionDotView!
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

        // Coworking suggestion indicator: amber dot on left side of notch
        suggestionDot = SuggestionDotView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))
        suggestionDot.alphaValue = 0
        container.addSubview(suggestionDot)

        // Observe learning state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(learningStateChanged(_:)),
            name: .learningStateChanged,
            object: nil
        )

        // Observe coworking suggestion state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(coworkingSuggestionChanged(_:)),
            name: .coworkingSuggestionAvailable,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(coworkingSuggestionDismissed(_:)),
            name: .coworkingSuggestionDismissed,
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

        // Learning dot: right side of notch, below the physical notch cutout
        let dotSize: CGFloat = 6
        learningDot.frame = CGRect(
            x: notchRect.width - dotSize - 8,
            y: 4,
            width: dotSize,
            height: dotSize
        )

        // Suggestion dot: left side of notch, below the physical notch cutout
        suggestionDot.frame = CGRect(
            x: 8,
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
            blackView.cancelRetraction()

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
            // Animate the mask path from expanded to collapsed — all edges of the
            // notch shape converge simultaneously instead of the bottom lagging.
            let expand: CGFloat = 5
            let fr = filletRadius
            let collapsedRect = CGRect(
                x: expand + fr,
                y: expand,
                width: originalFrame.width,
                height: originalFrame.height
            )

            blackView.animateRetraction(to: collapsedRect, duration: 0.25) { [weak self] in
                guard let self = self else { return }
                self.blackView.alphaValue = 0
                self.setFrame(self.originalFrame, display: true)
            }
        }
    }

    private func setDragHoverState(_ hovering: Bool) {
        guard hovering != isDragHovered else { return }
        isDragHovered = hovering

        if hovering {
            blackView.cancelRetraction()

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

    @objc private func coworkingSuggestionChanged(_ notification: Notification) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            suggestionDot.animator().alphaValue = 1.0
        }
    }

    @objc private func coworkingSuggestionDismissed(_ notification: Notification) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            suggestionDot.animator().alphaValue = 0.0
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
    private let shapeMask = CAShapeLayer()
    private var isAnimatingMask = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shapeMask
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if !isAnimatingMask {
            updateShapeMask()
        }
    }

    /// Generate the notch-shaped path within the given rect.
    func notchPath(in rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height
        let cr = min(bottomRadius, h / 2, (w - filletRadius * 2) / 2)
        let fr = filletRadius

        let bodyLeft = rect.minX + fr
        let bodyRight = rect.maxX - fr
        let bottom = rect.minY
        let top = rect.maxY

        let path = CGMutablePath()

        path.move(to: CGPoint(x: bodyLeft, y: bottom + cr))

        path.addArc(
            center: CGPoint(x: bodyLeft + cr, y: bottom + cr),
            radius: cr, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false
        )

        path.addLine(to: CGPoint(x: bodyRight - cr, y: bottom))

        path.addArc(
            center: CGPoint(x: bodyRight - cr, y: bottom + cr),
            radius: cr, startAngle: 3 * .pi / 2, endAngle: 0, clockwise: false
        )

        path.addLine(to: CGPoint(x: bodyRight, y: top - fr))

        path.addArc(
            center: CGPoint(x: rect.maxX, y: top - fr),
            radius: fr, startAngle: .pi, endAngle: .pi / 2, clockwise: true
        )

        path.addLine(to: CGPoint(x: rect.minX, y: top))

        path.addArc(
            center: CGPoint(x: rect.minX, y: top - fr),
            radius: fr, startAngle: .pi / 2, endAngle: 0, clockwise: true
        )

        path.addLine(to: CGPoint(x: bodyLeft, y: bottom + cr))

        path.closeSubpath()
        return path
    }

    /// Animate the mask from current full-bounds shape to a collapsed rect.
    func animateRetraction(to collapsedRect: CGRect, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let fromPath = notchPath(in: bounds)
        let toPath = notchPath(in: collapsedRect)

        isAnimatingMask = true
        shapeMask.path = toPath

        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = fromPath
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.isAnimatingMask = false
            completion()
        }
        shapeMask.add(anim, forKey: "retract")
        CATransaction.commit()
    }

    /// Cancel any running mask retraction and reset to full bounds.
    func cancelRetraction() {
        shapeMask.removeAnimation(forKey: "retract")
        isAnimatingMask = false
        updateShapeMask()
    }

    private func updateShapeMask() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        shapeMask.path = notchPath(in: bounds)
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

// MARK: - Coworking suggestion indicator dot (warm amber, left side)

class SuggestionDotView: NSView {
    private let dotLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Warm amber color — visually distinct from teal learning dot
        dotLayer.backgroundColor = NSColor(hue: 0.08, saturation: 0.5, brightness: 1.0, alpha: 0.8).cgColor
        dotLayer.cornerRadius = 3
        dotLayer.shadowColor = NSColor(hue: 0.08, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor
        dotLayer.shadowRadius = 4
        dotLayer.shadowOpacity = 0.6
        dotLayer.shadowOffset = .zero
        layer?.addSublayer(dotLayer)

        // Gentle pulse (slightly faster than learning dot to draw attention)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.4, 1.0, 0.4]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 2.0
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
