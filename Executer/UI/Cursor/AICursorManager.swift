import Cocoa
import CoreGraphics

/// Manages a custom colored cursor when the AI is controlling the computer.
/// Provides visual feedback (cursor color, trail, banner) and user takeback detection.
class AICursorManager {
    static let shared = AICursorManager()

    private(set) var isActive = false
    private var aiCursor: NSCursor?
    private var cursorColor: NSColor
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trailWindow: AICursorTrailWindow?
    private var onUserTakeback: (() -> Void)?

    /// The PID of our own process, used to distinguish AI-generated events from user events.
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {
        let hex = UserDefaults.standard.string(forKey: "aiCursorColor") ?? "8B5CF6"
        self.cursorColor = NSColor(hex: hex) ?? NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)
        self.aiCursor = Self.buildCursor(color: cursorColor)
    }

    // MARK: - Public API

    /// Start AI control mode: push custom cursor, show trail, install event tap.
    func startAIControl(onUserTakeback: (() -> Void)? = nil) {
        guard !isActive else { return }
        isActive = true
        self.onUserTakeback = onUserTakeback

        DispatchQueue.main.async { [self] in
            aiCursor?.push()
            if trailWindow == nil {
                trailWindow = AICursorTrailWindow()
            }
            trailWindow?.show()
            AIControlBanner.shared.show()
        }

        installEventTap()
    }

    /// Stop AI control mode: pop cursor, hide trail, remove event tap.
    func stopAIControl() {
        guard isActive else { return }
        isActive = false

        removeEventTap()

        DispatchQueue.main.async { [self] in
            NSCursor.pop()
            trailWindow?.hide()
            AIControlBanner.shared.hide()
        }
    }

    /// Update the cursor color. Regenerates the cursor image.
    func updateColor(_ color: NSColor) {
        cursorColor = color
        aiCursor = Self.buildCursor(color: color)

        // Persist
        if let hex = color.toHex() {
            UserDefaults.standard.set(hex, forKey: "aiCursorColor")
        }

        // If currently active, swap the cursor
        if isActive {
            DispatchQueue.main.async { [self] in
                NSCursor.pop()
                aiCursor?.push()
            }
        }
    }

    /// Feed a point to the trail window (call from mouse movement tools).
    func addTrailPoint(_ point: CGPoint) {
        trailWindow?.addPoint(point)
    }

    /// Set the stop callback (for ComputerUseAgent to cancel on user takeback).
    func setStopCallback(_ callback: @escaping () -> Void) {
        onUserTakeback = callback
    }

    // MARK: - Cursor Generation

    /// Generate an arrow cursor image filled with the given color.
    private static func buildCursor(color: NSColor, size: CGFloat = 24) -> NSCursor {
        let image = NSImage(size: NSSize(width: size, height: size * 1.4))
        image.lockFocus()

        // Classic arrow cursor shape
        let path = NSBezierPath()
        let w = size
        let h = size * 1.4
        path.move(to: NSPoint(x: 1, y: 1))              // Top-left tip
        path.line(to: NSPoint(x: 1, y: h - 2))          // Down left edge
        path.line(to: NSPoint(x: w * 0.35, y: h * 0.65))  // Inward notch
        path.line(to: NSPoint(x: w * 0.65, y: h - 2))   // Outward to tail
        path.line(to: NSPoint(x: w * 0.45, y: h * 0.55))  // Back inward
        path.line(to: NSPoint(x: w - 2, y: h * 0.42))   // Right tip
        path.line(to: NSPoint(x: 1, y: 1))               // Back to top
        path.close()

        // Fill with color
        color.setFill()
        path.fill()

        // Dark outline for visibility
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.0
        path.stroke()

        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: 1))
    }

    // MARK: - Event Tap (User Takeback Detection)

    /// Install a listen-only mouse-moved event tap.
    /// If the user (not our app) moves the mouse, stop AI control.
    private func installEventTap() {
        // Only listen for mouse moved events — no keyboard, no clicks
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<AICursorManager>.fromOpaque(refcon).takeUnretainedValue()

                // Check if the event came from our own process
                let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
                if sourcePID != 0 && sourcePID != Int64(manager.ownPID) {
                    // User moved the mouse — not our AI. Take back control.
                    DispatchQueue.main.async {
                        manager.stopAIControl()
                        manager.onUserTakeback?()
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else { return }
        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Remove the event tap.
    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    deinit {
        removeEventTap()
    }
}

// MARK: - NSColor Hex Helpers

private extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    func toHex() -> String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
