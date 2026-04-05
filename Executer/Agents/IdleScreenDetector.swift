import Foundation
import CoreGraphics

/// Detects when the Mac is unlocked and idle (no user input for 5+ minutes).
/// When idle, the overnight agent can use the screen to replay learned workflows.
/// When user returns (any input detected), immediately yields the screen.
class IdleScreenDetector {
    static let shared = IdleScreenDetector()

    /// Minimum idle time before the screen is considered available (seconds).
    private let idleThreshold: TimeInterval = 300  // 5 minutes

    /// Whether the screen is currently available for agent use.
    private(set) var isIdleAndAvailable = false

    /// Whether the screen is locked.
    private(set) var isScreenLocked = false

    private var pollTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        // Listen for screen lock/unlock
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )

        // Poll idle time every 30 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdleState()
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        isIdleAndAvailable = false
    }

    // MARK: - Idle Detection

    private func checkIdleState() {
        guard !isScreenLocked else {
            isIdleAndAvailable = false
            return
        }

        let idleSeconds = currentIdleTime()

        if idleSeconds >= idleThreshold && !isIdleAndAvailable {
            isIdleAndAvailable = true
            print("[IdleScreen] Mac idle for \(Int(idleSeconds))s — screen available for agent")
            NotificationCenter.default.post(name: .screenBecameIdle, object: nil)
        } else if idleSeconds < 30 && isIdleAndAvailable {
            // User returned — yield immediately
            isIdleAndAvailable = false
            print("[IdleScreen] User returned — yielding screen")
            NotificationCenter.default.post(name: .screenBecameActive, object: nil)
        }
    }

    /// Get seconds since last keyboard or mouse input.
    private func currentIdleTime() -> TimeInterval {
        // CGEventSource tracks all input across the session
        let idleTime = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!  // Any event type
        )
        return idleTime
    }

    // MARK: - Lock Handlers

    @objc private func screenDidLock() {
        isScreenLocked = true
        isIdleAndAvailable = false
    }

    @objc private func screenDidUnlock() {
        isScreenLocked = false
        // Don't immediately mark as available — wait for idle threshold
    }
}

extension Notification.Name {
    static let screenBecameIdle = Notification.Name("com.executer.screenBecameIdle")
    static let screenBecameActive = Notification.Name("com.executer.screenBecameActive")
}
