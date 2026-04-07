import Foundation
import ApplicationServices
import AppKit

/// Watches which URLs are visited in browsers by reading the address bar via AXUIElement.
/// Privacy: strips query parameters, only stores domain + path. Blacklisted domains are skipped.
/// Debounce: only logs a URL if the user stays on it for >= 3 seconds.
final class URLObserver {
    static let shared = URLObserver()

    /// Callback for each URL event.
    var onURLEvent: ((OEURLEvent) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var isRunning = false

    /// Last recorded URL — used for deduplication and duration tracking.
    private var lastURL: String = ""
    private var lastURLTimestamp: Date = .distantPast
    private var lastBrowserBundleId: String = ""
    private var lastPageTitle: String = ""

    /// Known browser bundle IDs.
    private let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",      // Arc
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Poll every 10 seconds — window title can change without app switch (tab switch)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.pollCurrentBrowser()
        }
        timer.resume()
        pollTimer = timer

        print("[URLObserver] Started — polling every 10s")
    }

    func stop() {
        isRunning = false
        // Emit final URL duration
        emitPendingURL()
        pollTimer?.cancel()
        pollTimer = nil
        print("[URLObserver] Stopped")
    }

    // MARK: - Polling

    private func pollCurrentBrowser() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier,
              browserBundleIds.contains(bundleId) else {
            // Not a browser — if we had a pending URL, emit it
            if !lastURL.isEmpty {
                emitPendingURL()
            }
            return
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Try to read URL from the address bar
        let url = readBrowserURL(app: appElement, bundleId: bundleId)
        let windowTitle = readWindowTitle(app: appElement) ?? frontApp.localizedName ?? ""

        guard let url = url, !url.isEmpty else {
            // Fallback: extract domain from window title
            if let domain = extractDomainFromTitle(windowTitle) {
                processURL(fullURL: domain, pageTitle: windowTitle, browserBundleId: bundleId)
            }
            return
        }

        processURL(fullURL: url, pageTitle: windowTitle, browserBundleId: bundleId)
    }

    private func processURL(fullURL: String, pageTitle: String, browserBundleId: String) {
        // Sanitize through PrivacyGuard
        guard let (domain, path) = PrivacyGuard.shared.sanitizeURL(fullURL) else { return }
        let canonicalURL = "\(domain)\(path)"

        // Deduplication — same URL, don't re-record
        if canonicalURL == lastURL { return }

        // Emit the previous URL with its duration (debounce: >= 3 seconds)
        emitPendingURL()

        // Start tracking the new URL
        lastURL = canonicalURL
        lastURLTimestamp = Date()
        lastBrowserBundleId = browserBundleId
        lastPageTitle = PrivacyGuard.shared.scrubSensitiveData(pageTitle)
    }

    /// Emit the currently tracked URL if it was viewed for >= 3 seconds.
    private func emitPendingURL() {
        guard !lastURL.isEmpty else { return }
        let duration = Date().timeIntervalSince(lastURLTimestamp)

        // Debounce: ignore URLs viewed < 3 seconds (accidental navigation)
        guard duration >= 3.0 else {
            lastURL = ""
            return
        }

        let components = lastURL.split(separator: "/", maxSplits: 1)
        let domain = String(components.first ?? "")
        let path = components.count > 1 ? "/\(components[1])" : "/"

        let event = OEURLEvent(
            timestamp: lastURLTimestamp,
            domain: domain,
            path: path,
            pageTitle: lastPageTitle,
            browserBundleId: lastBrowserBundleId,
            duration: duration
        )

        onURLEvent?(event)

        lastURL = ""
        lastPageTitle = ""
    }

    // MARK: - AXUIElement URL Reading

    /// Read the URL from the browser's address bar via Accessibility.
    private func readBrowserURL(app: AXUIElement, bundleId: String) -> String? {
        switch bundleId {
        case "com.apple.Safari":
            return readSafariURL(app: app)
        default:
            // Chrome, Arc, Brave, Edge, etc. — try generic approach
            return readChromiumURL(app: app) ?? readGenericURL(app: app)
        }
    }

    /// Safari: the URL is in the focused window's toolbar → group → text field with AXValue.
    private func readSafariURL(app: AXUIElement) -> String? {
        guard let window = getFocusedWindow(app) else { return nil }

        // Safari's address bar: window → toolbar → group → text field (or combo box)
        guard let toolbar = findChild(of: window, role: "AXToolbar") else { return nil }

        // The URL field is usually a text field or combo box within the toolbar
        if let urlField = findDescendant(of: toolbar, role: "AXTextField") {
            return getStringAttr(urlField, kAXValueAttribute)
        }
        if let comboBox = findDescendant(of: toolbar, role: "AXComboBox") {
            return getStringAttr(comboBox, kAXValueAttribute)
        }

        return nil
    }

    /// Chrome/Chromium-based: address bar is an AXTextField with identifier or in toolbar.
    private func readChromiumURL(app: AXUIElement) -> String? {
        guard let window = getFocusedWindow(app) else { return nil }

        // Try to find the address bar by traversing the toolbar area
        if let toolbar = findChild(of: window, role: "AXToolbar") {
            if let urlField = findDescendant(of: toolbar, role: "AXTextField") {
                return getStringAttr(urlField, kAXValueAttribute)
            }
        }

        // Chrome sometimes nests it differently — try direct children
        if let group = findChild(of: window, role: "AXGroup") {
            if let urlField = findDescendant(of: group, role: "AXTextField") {
                return getStringAttr(urlField, kAXValueAttribute)
            }
        }

        return nil
    }

    /// Generic: try to find any URL-like text field in the window.
    private func readGenericURL(app: AXUIElement) -> String? {
        guard let window = getFocusedWindow(app) else { return nil }

        // BFS for any text field whose value looks like a URL
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < 50 {  // Cap traversal to avoid perf issues
            let element = queue.removeFirst()
            visited += 1

            if let role = getStringAttr(element, kAXRoleAttribute),
               role == "AXTextField" || role == "AXComboBox" {
                if let value = getStringAttr(element, kAXValueAttribute),
                   value.contains("://") || value.contains(".com") || value.contains(".org") {
                    return value
                }
            }

            // Add children to BFS queue
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(10))  // Limit breadth
            }
        }

        return nil
    }

    /// Extract domain from window title as fallback. E.g., "GitHub - repo" → "github.com"
    private func extractDomainFromTitle(_ title: String) -> String? {
        // Many browsers put " - domain" or "domain - " in the title
        let lowered = title.lowercased()
        // Check for common domain patterns in the title
        let domainPattern = try? NSRegularExpression(pattern: #"(?:https?://)?([a-z0-9][-a-z0-9]*\.[a-z]{2,})"#)
        if let match = domainPattern?.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let range = Range(match.range(at: 1), in: lowered) {
            return String(lowered[range])
        }
        return nil
    }

    // MARK: - AXUIElement Helpers

    private func getFocusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return nil }
        return (windowRef as! AXUIElement)
    }

    private func readWindowTitle(app: AXUIElement) -> String? {
        guard let window = getFocusedWindow(app) else { return nil }
        return getStringAttr(window, kAXTitleAttribute)
    }

    /// Find a direct child with the given role.
    private func findChild(of element: AXUIElement, role: String) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if getStringAttr(child, kAXRoleAttribute) == role {
                return child
            }
        }
        return nil
    }

    /// BFS to find a descendant with the given role (max depth 4).
    private func findDescendant(of element: AXUIElement, role: String) -> AXUIElement? {
        var queue: [AXUIElement] = [element]
        var visited = 0
        while !queue.isEmpty && visited < 30 {
            let current = queue.removeFirst()
            visited += 1
            if getStringAttr(current, kAXRoleAttribute) == role && current as CFTypeRef as AnyObject !== element as CFTypeRef as AnyObject {
                return current
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(8))
            }
        }
        return nil
    }

    private func getStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
