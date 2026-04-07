import Foundation
import AppKit

/// Watches app-to-app and URL-to-URL transitions — the sequences of user actions.
/// Built on top of AppObserver (app switches) and URLObserver (URL changes).
/// Includes full context: time of day, day of week, focus mode, interaction mode.
/// These transitions are the MOST VALUABLE data for learning workflows and sequences.
final class TransitionObserver {
    static let shared = TransitionObserver()

    /// Callback for each transition event.
    var onTransitionEvent: ((OETransitionEvent) -> Void)?

    /// Callback for each app duration event (emitted when user leaves an app).
    var onAppEvent: ((OEAppEvent) -> Void)?

    private var isRunning = false

    // State tracking for the previous app/context
    private let stateLock = NSLock()
    private var previousApp: String = ""         // bundle ID
    private var previousContext: String = ""      // window title or domain
    private var previousAppName: String = ""      // display name
    private var previousTimestamp: Date = .distantPast

    // Debounce: ignore app switches < 2 seconds (accidental Cmd-Tab)
    private let debounceThreshold: TimeInterval = 2.0

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Listen for app activation changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Initialize state with current frontmost app
        if let app = NSWorkspace.shared.frontmostApplication {
            stateLock.lock()
            previousApp = app.bundleIdentifier ?? "unknown"
            previousAppName = app.localizedName ?? "Unknown"
            previousContext = readWindowTitle(pid: app.processIdentifier) ?? ""
            previousTimestamp = Date()
            stateLock.unlock()
        }

        print("[TransitionObserver] Started")
    }

    func stop() {
        isRunning = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        // Emit final app duration
        emitAppDuration()

        print("[TransitionObserver] Stopped")
    }

    // MARK: - App Switch Detection

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown"

        // Don't observe Executer itself
        guard bundleId != "com.allenwu.executer" else { return }

        // Privacy check
        guard PrivacyGuard.shared.shouldObserveApp(bundleId: bundleId) else { return }

        let windowTitle = readWindowTitle(pid: app.processIdentifier) ?? ""

        // Privacy: check window title
        guard PrivacyGuard.shared.shouldObserveWindowTitle(windowTitle) else { return }

        let now = Date()

        stateLock.lock()
        let prevApp = previousApp
        let prevContext = previousContext
        let prevAppName = previousAppName
        let prevTimestamp = previousTimestamp

        // Update state to new app
        previousApp = bundleId
        previousAppName = appName
        previousContext = PrivacyGuard.shared.scrubSensitiveData(windowTitle)
        previousTimestamp = now
        stateLock.unlock()

        // Debounce: ignore if previous app was active < 2 seconds
        let prevDuration = now.timeIntervalSince(prevTimestamp)
        guard prevDuration >= debounceThreshold else { return }

        // Skip if same app (shouldn't happen but guard)
        guard prevApp != bundleId else { return }

        // Emit the previous app's duration event
        if !prevApp.isEmpty {
            let focusMode = { let m = FocusStateService.shared.currentFocus; return m == .none ? nil : m.displayName }()
            let appEvent = OEAppEvent(
                timestamp: prevTimestamp,
                bundleId: prevApp,
                appName: prevAppName,
                windowTitle: prevContext,
                duration: prevDuration,
                focusMode: focusMode
            )
            onAppEvent?(appEvent)
        }

        // Emit the transition event
        if !prevApp.isEmpty {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .weekday], from: now)
            let hour = components.hour ?? 0
            let calWeekday = components.weekday ?? 1
            let isoWeekday = calWeekday == 1 ? 7 : calWeekday - 1

            let focusMode = { let m = FocusStateService.shared.currentFocus; return m == .none ? nil : m.displayName }()
            let currentInteraction = ActivityObserver.shared.currentMode

            let scrubbed = PrivacyGuard.shared.scrubSensitiveData(windowTitle)

            let transition = OETransitionEvent(
                timestamp: now,
                fromApp: prevApp,
                fromContext: prevContext,
                toApp: bundleId,
                toContext: scrubbed,
                interactionMode: currentInteraction,
                focusMode: focusMode,
                hourOfDay: hour,
                dayOfWeek: isoWeekday
            )

            onTransitionEvent?(transition)
        }
    }

    /// Called by URLObserver when the URL changes within a browser — intra-app transition.
    func recordURLTransition(fromDomain: String, fromTitle: String, toDomain: String, toTitle: String, browserBundleId: String) {
        guard isRunning else { return }
        guard fromDomain != toDomain || fromTitle != toTitle else { return }

        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .weekday], from: now)
        let hour = components.hour ?? 0
        let calWeekday = components.weekday ?? 1
        let isoWeekday = calWeekday == 1 ? 7 : calWeekday - 1

        let focusMode = { let m = FocusStateService.shared.currentFocus; return m == .none ? nil : m.displayName }()
        let currentInteraction = ActivityObserver.shared.currentMode

        let transition = OETransitionEvent(
            timestamp: now,
            fromApp: browserBundleId,
            fromContext: fromDomain.isEmpty ? fromTitle : fromDomain,
            toApp: browserBundleId,
            toContext: toDomain.isEmpty ? toTitle : toDomain,
            interactionMode: currentInteraction,
            focusMode: focusMode,
            hourOfDay: hour,
            dayOfWeek: isoWeekday
        )

        onTransitionEvent?(transition)
    }

    // MARK: - Helpers

    private func emitAppDuration() {
        stateLock.lock()
        let app = previousApp
        let name = previousAppName
        let context = previousContext
        let timestamp = previousTimestamp
        stateLock.unlock()

        guard !app.isEmpty else { return }
        let duration = Date().timeIntervalSince(timestamp)
        guard duration >= debounceThreshold else { return }

        let focusMode = { let m = FocusStateService.shared.currentFocus; return m == .none ? nil : m.displayName }()
        let event = OEAppEvent(
            timestamp: timestamp,
            bundleId: app,
            appName: name,
            windowTitle: context,
            duration: duration,
            focusMode: focusMode
        )
        onAppEvent?(event)
    }

    private func readWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }
}
