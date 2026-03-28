import Foundation
import ApplicationServices
import AppKit

/// Observes user interactions with apps in the background via Accessibility notifications.
/// Captures focus changes, text edits, and window events to build action sequences.
/// Privacy: never captures from secure text fields, all data stays local.
class AppObserver {
    static let shared = AppObserver()

    private var observer: AXObserver?
    private var currentPID: pid_t = 0
    private var currentAppName: String = ""
    private var isRunning = false

    /// Callback: invoked when a new action is observed.
    var onAction: ((UserAction) -> Void)?

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Watch for app activation changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Start observing current frontmost app
        if let app = NSWorkspace.shared.frontmostApplication {
            startObservingApp(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")
        }

        print("[AppObserver] Started background observation")
    }

    func stop() {
        isRunning = false
        stopObservingCurrentApp()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        print("[AppObserver] Stopped")
    }

    // MARK: - App Switching

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Unknown"

        // Don't observe ourselves
        if app.bundleIdentifier == "com.allenwu.executer" { return }

        if pid != currentPID {
            stopObservingCurrentApp()
            startObservingApp(pid: pid, name: name)
        }
    }

    // MARK: - AXObserver Setup

    private func startObservingApp(pid: pid_t, name: String) {
        currentPID = pid
        currentAppName = name

        var obs: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &obs)
        guard result == .success, let newObserver = obs else {
            print("[AppObserver] Failed to create observer for \(name) (pid \(pid))")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Watch for focus changes (what the user clicks on / tabs to)
        AXObserverAddNotification(newObserver, appElement, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Watch for value changes (text editing)
        AXObserverAddNotification(newObserver, appElement, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Watch for window created
        AXObserverAddNotification(newObserver, appElement, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Watch for menu item selected
        AXObserverAddNotification(newObserver, appElement, kAXMenuItemSelectedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

        self.observer = newObserver
    }

    private func stopObservingCurrentApp() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = nil
        }
    }

    // MARK: - Notification Handler

    fileprivate func handleNotification(_ notification: String, element: AXUIElement) {
        let role = getStringAttr(element, kAXRoleAttribute) ?? ""
        let subrole = getStringAttr(element, kAXSubroleAttribute) ?? ""
        let title = getStringAttr(element, kAXTitleAttribute) ?? ""

        // Skip secure fields
        if subrole == "AXSecureTextField" { return }

        let value: String
        if notification == kAXValueChangedNotification as String {
            value = String((getStringAttr(element, kAXValueAttribute) ?? "").prefix(200))
        } else {
            value = ""
        }

        let actionType: UserAction.ActionType
        switch notification {
        case kAXFocusedUIElementChangedNotification as String:
            // Determine if this is a click (button/menu) or just a focus change
            if ["AXButton", "AXMenuItem", "AXLink", "AXTab"].contains(role) {
                actionType = .click
            } else {
                actionType = .focus
            }
        case kAXValueChangedNotification as String:
            actionType = .textEdit
        case kAXWindowCreatedNotification as String:
            actionType = .windowOpen
        case kAXMenuItemSelectedNotification as String:
            actionType = .menuSelect
        default:
            return
        }

        let action = UserAction(
            type: actionType,
            appName: currentAppName,
            elementRole: role,
            elementTitle: title,
            elementValue: value,
            timestamp: Date()
        )

        onAction?(action)
    }

    private func getStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - C Callback (bridges to AppObserver instance)

private func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let appObserver = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.handleNotification(notification as String, element: element)
}
