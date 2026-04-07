import Cocoa
import QuartzCore

/// A transparent overlay window that draws a fading trail behind the AI cursor.
/// Points expire after 0.5 seconds for a smooth fade effect.
class AICursorTrailWindow {
    private var window: NSWindow?
    private var trailView: AICursorTrailView?

    init() {
        setupWindow()
    }

    func show() {
        window?.orderFront(nil)
        trailView?.startRendering()
    }

    func hide() {
        trailView?.stopRendering()
        trailView?.clearPoints()
        window?.orderOut(nil)
    }

    /// Add a point to the trail. Called from mouse movement tools.
    func addPoint(_ point: CGPoint) {
        // Convert CG coordinates (top-left origin) to screen coordinates (bottom-left origin)
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let nsPoint = NSPoint(x: point.x, y: screenHeight - point.y)
        trailView?.addPoint(nsPoint)
    }

    private func setupWindow() {
        guard let screen = NSScreen.main else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.hasShadow = false

        let view = AICursorTrailView(frame: screen.frame)
        win.contentView = view

        self.window = win
        self.trailView = view
    }
}

// MARK: - Trail View

private class AICursorTrailView: NSView {
    private struct TrailPoint {
        let position: NSPoint
        let timestamp: Date
    }

    private var points: [TrailPoint] = []
    private var displayLink: CVDisplayLink?
    private let maxAge: TimeInterval = 0.5
    private let maxPoints = 50
    private let trailColor: NSColor

    override init(frame: NSRect) {
        let hex = UserDefaults.standard.string(forKey: "aiCursorColor") ?? "8B5CF6"
        if let r = UInt64(hex, radix: 16) {
            trailColor = NSColor(
                red: CGFloat((r >> 16) & 0xFF) / 255.0,
                green: CGFloat((r >> 8) & 0xFF) / 255.0,
                blue: CGFloat(r & 0xFF) / 255.0,
                alpha: 1.0
            )
        } else {
            trailColor = NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func addPoint(_ point: NSPoint) {
        points.append(TrailPoint(position: point, timestamp: Date()))
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
    }

    func clearPoints() {
        points.removeAll()
        needsDisplay = true
    }

    func startRendering() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context -> CVReturn in
            guard let context = context else { return kCVReturnSuccess }
            let view = Unmanaged<AICursorTrailView>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                view.pruneAndRedraw()
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopRendering() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    private func pruneAndRedraw() {
        let now = Date()
        points.removeAll { now.timeIntervalSince($0.timestamp) > maxAge }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !points.isEmpty else { return }

        let now = Date()

        for point in points {
            let age = now.timeIntervalSince(point.timestamp)
            let alpha = max(0, 1.0 - age / maxAge)
            let radius = CGFloat(3.0 + alpha * 3.0) // 3-6pt radius

            let color = trailColor.withAlphaComponent(CGFloat(alpha) * 0.6)
            color.setFill()

            let circle = NSBezierPath(ovalIn: NSRect(
                x: point.position.x - radius,
                y: point.position.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            circle.fill()
        }
    }

    deinit {
        stopRendering()
    }
}
