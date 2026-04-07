import Foundation
import CoreGraphics
import AppKit

/// Watches user interaction intensity to distinguish active use from passive drift (Principle 4).
/// Uses a CGEvent tap in `.listenOnly` mode to count keystrokes, clicks, and scroll distance.
/// CRITICAL: never records WHICH keys were pressed. Only counts. This is a privacy hard line.
final class ActivityObserver {
    static let shared = ActivityObserver()

    /// Callback for each 30-second activity window.
    var onActivityEvent: ((OEActivityEvent) -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var windowTimer: DispatchSourceTimer?
    private var isRunning = false

    // Accumulating counters for the current 30-second window
    private let countersLock = NSLock()
    private var keystrokes: Int = 0
    private var clicks: Int = 0
    private var scrollDistance: CGFloat = 0
    private var windowStart: Date = Date()

    /// The last emitted interaction mode — used by TransitionObserver.
    private(set) var currentMode: InteractionMode = .idle

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        startEventTap()
        startWindowTimer()

        print("[ActivityObserver] Started — 30s windows, passive CGEvent tap")
    }

    func stop() {
        isRunning = false

        // Emit final window
        emitCurrentWindow()

        windowTimer?.cancel()
        windowTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }

        print("[ActivityObserver] Stopped")
    }

    // MARK: - CGEvent Tap

    private func startEventTap() {
        // Listen for: keyDown, leftMouseDown, rightMouseDown, scrollWheel
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        // .listenOnly so we never interfere with events — just count them
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: activityTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[ActivityObserver] Failed to create event tap — Input Monitoring permission needed")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Called from the CGEvent tap callback — just increments counters.
    fileprivate func recordEvent(type: CGEventType, event: CGEvent) {
        countersLock.lock()
        defer { countersLock.unlock() }

        switch type {
        case .keyDown:
            keystrokes += 1
        case .leftMouseDown, .rightMouseDown:
            clicks += 1
        case .scrollWheel:
            // Accumulate absolute scroll distance
            let deltaY = abs(event.getDoubleValueField(.scrollWheelEventDeltaAxis1))
            let deltaX = abs(event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
            scrollDistance += CGFloat(deltaY + deltaX)
        default:
            break
        }
    }

    // MARK: - 30-Second Window Timer

    private func startWindowTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.emitCurrentWindow()
        }
        timer.resume()
        windowTimer = timer
    }

    private func emitCurrentWindow() {
        countersLock.lock()
        let ks = keystrokes
        let cl = clicks
        let sd = scrollDistance
        let start = windowStart

        // Reset for next window
        keystrokes = 0
        clicks = 0
        scrollDistance = 0
        windowStart = Date()
        countersLock.unlock()

        let interval = Date().timeIntervalSince(start)
        let mode = InteractionMode.classify(keystrokes: ks, clicks: cl, scrollDistance: sd)
        currentMode = mode

        // Don't emit idle windows — saves storage
        guard mode != .idle else { return }

        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

        let event = OEActivityEvent(
            timestamp: start,
            windowInterval: interval,
            keystrokes: ks,
            clicks: cl,
            scrollDistance: sd,
            appBundleId: bundleId,
            interactionMode: mode
        )

        onActivityEvent?(event)
    }
}

// MARK: - CGEvent Tap C Callback

private func activityTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // If the tap gets disabled by the system, re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let observer = Unmanaged<ActivityObserver>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = observer.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let observer = Unmanaged<ActivityObserver>.fromOpaque(userInfo).takeUnretainedValue()
    observer.recordEvent(type: type, event: event)

    return Unmanaged.passRetained(event)
}
