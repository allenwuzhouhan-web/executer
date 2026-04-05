import Cocoa
import ApplicationServices

actor TextSnapshotService {
    static let shared = TextSnapshotService()

    private let db = ThoughtDatabase.shared
    private var captureTask: Task<Void, Never>?
    private var lastTextHash: [String: Int] = [:]  // bundleId -> hash
    private var paused = false
    private let captureInterval: TimeInterval = 5.0
    private let maxTextLength = 10_000
    private let changeThreshold = 0.20

    private let ownBundleId = Bundle.main.bundleIdentifier ?? "com.allenwu.executer"

    // MARK: - Lifecycle

    func start() {
        guard captureTask == nil else { return }
        print("[TextSnapshot] Starting")

        // Listen for screen lock/unlock
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.setPaused(true) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.setPaused(false) }
        }

        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.captureInterval ?? 5.0))
                await self?.captureSnapshot()
            }
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        print("[TextSnapshot] Stopped")
    }

    private func setPaused(_ value: Bool) {
        paused = value
        print("[TextSnapshot] \(value ? "Paused" : "Resumed") (screen lock)")
    }

    // MARK: - Capture

    private func captureSnapshot() async {
        guard !paused else { return }

        // Get frontmost app on main thread
        guard let appInfo = await MainActor.run(body: { () -> (pid: pid_t, bundleId: String, name: String)? in
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleId = app.bundleIdentifier,
                  let name = app.localizedName else { return nil }
            return (app.processIdentifier, bundleId, name)
        }) else { return }

        // Skip own app
        guard appInfo.bundleId != ownBundleId else { return }

        // Read text from focused element with timeout
        let result = await withTaskGroup(of: CapturedText?.self) { group in
            group.addTask {
                return self.readFocusedText(pid: appInfo.pid)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return nil  // timeout sentinel
            }

            var capturedText: CapturedText?
            for await value in group {
                if let v = value {
                    capturedText = v
                    group.cancelAll()
                    break
                }
            }
            return capturedText
        }

        guard let captured = result else { return }
        guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Truncate
        let text = String(captured.text.prefix(maxTextLength))

        // Debounce: only save if text changed significantly
        let newHash = text.hashValue
        if let oldHash = lastTextHash[appInfo.bundleId], oldHash == newHash {
            return
        }

        // Check change ratio against last DB entry
        if let lastThought = db.mostRecentForApp(bundleId: appInfo.bundleId) {
            let ratio = changeRatio(old: lastThought.textContent, new: text)
            if ratio < changeThreshold {
                lastTextHash[appInfo.bundleId] = newHash
                return
            }
        }

        lastTextHash[appInfo.bundleId] = newHash

        // Get window title on main thread
        let windowTitle = await MainActor.run {
            let appElement = AXUIElementCreateApplication(appInfo.pid)
            var windowValue: AnyObject?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
                  let wv = windowValue else {
                return nil as String?
            }
            var titleValue: AnyObject?
            // CFType cast always succeeds — safety comes from the nil guard above
            guard AXUIElementCopyAttributeValue(wv as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else {
                return nil as String?
            }
            return titleValue as? String
        }

        db.insert(
            appBundleId: appInfo.bundleId,
            appName: appInfo.name,
            windowTitle: windowTitle,
            textContent: text
        )

        print("[TextSnapshot] Captured from \(appInfo.name): \(text.prefix(60))...")
    }

    // MARK: - AXUIElement Reading

    private struct CapturedText {
        let text: String
        let isPassword: Bool
    }

    private nonisolated func readFocusedText(pid: pid_t) -> CapturedText? {
        let appElement = AXUIElementCreateApplication(pid)

        // Get focused UI element
        var focusedValue: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusResult == .success, let focused = focusedValue else { return nil }

        // CFType cast always succeeds — safety comes from the nil guard above
        let element = focused as! AXUIElement

        // Check role — only capture text inputs
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard let role = roleValue as? String else { return nil }

        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXWebArea", "AXComboBox"]
        guard textRoles.contains(role) else { return nil }

        // Check if password field — NEVER capture passwords
        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if let subrole = subroleValue as? String, subrole == "AXSecureTextField" {
            return nil
        }

        // Read value
        var textValue: AnyObject?
        let readResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue)
        guard readResult == .success, let text = textValue as? String else { return nil }

        return CapturedText(text: text, isPassword: false)
    }

    // MARK: - Change Detection

    private func changeRatio(old: String, new: String) -> Double {
        // Simple character-level change ratio
        if old.isEmpty && new.isEmpty { return 0 }
        if old.isEmpty || new.isEmpty { return 1.0 }

        let oldChars = Set(old)
        let newChars = Set(new)
        let union = oldChars.union(newChars)
        let intersection = oldChars.intersection(newChars)

        guard !union.isEmpty else { return 0 }

        let similarity = Double(intersection.count) / Double(union.count)
        let lengthRatio = abs(Double(new.count - old.count)) / Double(max(old.count, new.count))

        return 1.0 - similarity + lengthRatio * 0.5
    }
}
