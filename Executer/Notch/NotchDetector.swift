import Cocoa

/// Detects clicks in the notch region using a CGEvent tap.
/// CGEvent tap operates in CG coordinates (top-left origin, same as Cmd+Shift+4 screenshot tool),
/// which lets us detect clicks in the menu bar / notch area that normal NSEvent monitors miss.
class NotchDetector {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private let onNotchClick: () -> Void
    /// Cached screen height to avoid repeated NSScreen lookups in CGEvent callback
    private var cachedScreenHeight: CGFloat = 982

    /// The click zone in CG coordinates (origin = top-left of main display).
    /// Defaults to auto-detected notch area; can be overridden by the user.
    private(set) var clickZone: CGRect

    init(onNotchClick: @escaping () -> Void) {
        self.onNotchClick = onNotchClick
        self.clickZone = NotchDetector.autoDetectZone()
    }

    /// Auto-detect the notch click zone in CG coordinates (top-left origin).
    static func autoDetectZone() -> CGRect {
        guard let screen = NSScreen.builtIn else {
            // Fallback: center of main screen, top 38px
            let mainFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
            let zoneWidth: CGFloat = 300
            return CGRect(
                x: mainFrame.width / 2 - zoneWidth / 2,
                y: 0,
                width: zoneWidth,
                height: 38
            )
        }

        let frame = screen.frame
        // Check for notch
        let topInset = frame.maxY - screen.visibleFrame.maxY
        let hasNotch = topInset > 30

        // CG coordinates: origin at top-left, y increases downward
        // The notch occupies the top ~33-38px, centered horizontally
        let zoneHeight: CGFloat = hasNotch ? max(topInset, 38) : 38
        let zoneWidth: CGFloat = hasNotch ? 300 : 200
        let zoneX = frame.width / 2 - zoneWidth / 2

        let zone = CGRect(x: zoneX, y: 0, width: zoneWidth, height: zoneHeight)
        print("[NotchDetector] Auto-detected zone (CG coords): \(zone)")
        print("[NotchDetector] Screen: \(frame.width)x\(frame.height), topInset: \(topInset), hasNotch: \(hasNotch)")
        return zone
    }

    /// Set a custom click zone (in CG coordinates, top-left origin).
    func setCustomZone(_ rect: CGRect) {
        clickZone = rect
        UserDefaults.standard.set(NSStringFromRect(NSRect(cgRect: rect)), forKey: "notch_click_zone")
        print("[NotchDetector] Custom zone set: \(rect)")
    }

    /// Load saved custom zone, if any.
    func loadSavedZone() {
        if let saved = UserDefaults.standard.string(forKey: "notch_click_zone") {
            let rect = NSRectFromString(saved)
            if rect.width > 0 && rect.height > 0 {
                clickZone = CGRect(rect: rect)
                print("[NotchDetector] Loaded saved zone: \(clickZone)")
            }
        }
    }

    func start() {
        loadSavedZone()
        cachedScreenHeight = NSScreen.main?.frame.height ?? 982
        print("[NotchDetector] Starting with click zone: \(clickZone)")

        // Strategy 1: CGEvent tap — intercepts clicks at the lowest level,
        // works even in the menu bar / notch area where NSEvent monitors fail.
        startEventTap()

        // Strategy 2: Global NSEvent monitor as fallback
        // Note: only fires for clicks OUTSIDE the app's own windows (global monitor).
        // This prevents firing when clicking on the input bar itself.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self else { return }
            let nsPoint = NSEvent.mouseLocation
            let cgPoint = CGPoint(x: nsPoint.x, y: self.cachedScreenHeight - nsPoint.y)

            if self.clickZone.contains(cgPoint) {
                print("[NotchDetector] Global monitor: click in zone at CG(\(cgPoint.x), \(cgPoint.y))")
                DispatchQueue.main.async {
                    self.onNotchClick()
                }
            }
        }
    }

    private func startEventTap() {
        // We need a context pointer to pass our callback reference
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // Don't consume the event, just observe
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let detector = Unmanaged<NotchDetector>.fromOpaque(refcon).takeUnretainedValue()

                let location = event.location

                if detector.clickZone.contains(location) {
                    // Check if the click is on our own window (input bar) — if so, ignore
                    // to prevent closing the bar when clicking on it
                    let screenH = detector.cachedScreenHeight
                    let isOnOurWindow = NSApp.windows.contains { window in
                        guard window.isVisible, !window.ignoresMouseEvents else { return false }
                        // Convert CG coords to NS coords for comparison
                        let nsPoint = NSPoint(x: location.x, y: screenH - location.y)
                        return window.frame.contains(nsPoint)
                    }

                    if !isOnOurWindow {
                        print("[NotchDetector] CGEvent tap: click in zone at CG(\(location.x), \(location.y))")
                        DispatchQueue.main.async {
                            detector.onNotchClick()
                        }
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: refcon
        ) else {
            print("[NotchDetector] Failed to create CGEvent tap — need Accessibility / Input Monitoring permission")
            return
        }

        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[NotchDetector] CGEvent tap started successfully")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    deinit {
        stop()
    }
}

// Helper for NSRect <-> CGRect on macOS
private extension CGRect {
    init(rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
}

private extension NSRect {
    init(cgRect: CGRect) {
        self.init(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.size.width, height: cgRect.size.height)
    }
}
