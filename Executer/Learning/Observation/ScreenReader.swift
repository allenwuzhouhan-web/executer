import Foundation
import ApplicationServices
import AppKit

/// Reads the full UI tree of any running application via Accessibility APIs.
/// No screen recording permission needed — uses AXUIElement to traverse the element hierarchy.
/// Can read text, buttons, menus, fields, labels, and their positions from any app.
enum ScreenReader {

    // MARK: - Cache

    /// Time-based cache to avoid redundant AX tree walks within a short window.
    private static let cacheLock = NSLock()
    private static var cachedSnapshot: AppSnapshot?
    private static var cacheTimestamp: Date = .distantPast
    private static var cachePID: pid_t = 0
    /// Cache TTL in seconds. AX reads are ~50ms; caching avoids duplicates within 150ms.
    static var cacheTTL: TimeInterval = 0.15

    /// Invalidate the cache (call after performing a UI action that changes the screen).
    static func invalidateCache() {
        cacheLock.lock()
        cachedSnapshot = nil
        cacheLock.unlock()
    }

    // MARK: - Full UI Tree Reading

    /// Reads the entire visible UI tree of the frontmost application.
    /// Returns a cached result if within TTL, otherwise performs a fresh AX read.
    static func readFrontmostApp() -> AppSnapshot? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        // Check cache
        cacheLock.lock()
        if pid == cachePID, let cached = cachedSnapshot,
           Date().timeIntervalSince(cacheTimestamp) < cacheTTL {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = readApp(pid: pid, name: frontApp.localizedName ?? "Unknown")

        // Store in cache
        if let result = result {
            cacheLock.lock()
            cachedSnapshot = result
            cacheTimestamp = Date()
            cachePID = pid
            cacheLock.unlock()
        }
        return result
    }

    /// Reads the UI tree of a specific application by PID.
    static func readApp(pid: pid_t, name: String) -> AppSnapshot? {
        let appElement = AXUIElementCreateApplication(pid)

        // Get focused window
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowElement = windowValue else {
            return nil
        }

        // CFType cast always succeeds — safety comes from the nil guard above
        let windowAX = windowElement as! AXUIElement
        let windowTitle = getStringAttribute(windowAX, kAXTitleAttribute) ?? ""

        // Progressive depth: try shallow first (depth 6), deepen to 12 if insufficient
        var elements: [UIElementSnapshot] = []
        traverseElement(windowAX, depth: 0, maxDepth: 6, elements: &elements)

        let interactiveCount = elements.filter { isInteractiveRole($0.role) }.count
        if interactiveCount < 5 {
            // Shallow read was insufficient — do a full deep read
            elements.removeAll()
            traverseElement(windowAX, depth: 0, maxDepth: 12, elements: &elements)
        }

        return AppSnapshot(
            appName: name,
            pid: pid,
            windowTitle: windowTitle,
            elements: elements,
            timestamp: Date()
        )
    }

    /// Roles considered interactive for sufficiency threshold.
    static func isInteractiveRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXMenuItem", "AXTextField", "AXTextArea",
             "AXCheckBox", "AXRadioButton", "AXPopUpButton",
             "AXSlider", "AXLink", "AXTab", "AXToolbar",
             "AXComboBox", "AXIncrementor", "AXColorWell":
            return true
        default:
            return false
        }
    }

    /// Read a targeted subtree by finding an element near a specific screen point.
    /// Useful for refreshing only the area around a recently-clicked element.
    static func readSubtree(pid: pid_t, near point: CGPoint, radius: CGFloat = 200) -> [UIElementSnapshot] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowElement = windowValue else { return [] }

        var allElements: [UIElementSnapshot] = []
        traverseElement(windowElement as! AXUIElement, depth: 0, maxDepth: 12, elements: &allElements)

        // Filter to elements within radius of the target point
        return allElements.filter { el in
            guard let pos = el.position, let size = el.size else { return false }
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            let dx = center.x - point.x
            let dy = center.y - point.y
            return (dx * dx + dy * dy) <= (radius * radius)
        }
    }

    /// Reads just the text content visible in the frontmost app (lightweight).
    static func readVisibleText(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowElement = windowValue else {
            return []
        }

        var texts: [String] = []
        collectText(windowElement as! AXUIElement, depth: 0, maxDepth: 10, texts: &texts)
        return texts
    }

    // MARK: - Element Traversal

    /// Maximum elements to collect before stopping traversal (prevents runaway on huge trees).
    private static let maxElements = 500

    private static func traverseElement(_ element: AXUIElement, depth: Int, maxDepth: Int, elements: inout [UIElementSnapshot]) {
        guard depth < maxDepth, elements.count < maxElements else { return }

        let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = getStringAttribute(element, kAXSubroleAttribute) ?? ""

        // Skip secure text fields (passwords)
        if subrole == "AXSecureTextField" { return }

        // Skip deep container-only roles that bloat the tree without useful info
        if depth > 4 && !isInteractiveRole(role) {
            let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
            let value = getStringAttribute(element, kAXValueAttribute) ?? ""
            if title.isEmpty && value.isEmpty {
                // Still recurse children — the interesting elements are deeper
                recurseChildren(element, depth: depth, maxDepth: maxDepth, elements: &elements)
                return
            }
        }

        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
        let value = getStringAttribute(element, kAXValueAttribute) ?? ""
        let description = getStringAttribute(element, kAXDescriptionAttribute) ?? ""
        let label = getStringAttribute(element, kAXLabelValueAttribute ?? "AXLabel") ?? ""
        let identifier = getStringAttribute(element, "AXIdentifier") ?? ""

        // Only record elements with meaningful content or interactive role
        let hasContent = !title.isEmpty || !value.isEmpty || !description.isEmpty || !label.isEmpty

        if hasContent || isInteractiveRole(role) {
            let position = getPosition(element)
            let size = getSize(element)

            elements.append(UIElementSnapshot(
                role: role,
                subrole: subrole,
                title: title,
                value: String(value.prefix(500)),
                description: description,
                label: label,
                identifier: identifier,
                position: position,
                size: size,
                depth: depth
            ))
        }

        recurseChildren(element, depth: depth, maxDepth: maxDepth, elements: &elements)
    }

    private static func recurseChildren(_ element: AXUIElement, depth: Int, maxDepth: Int, elements: inout [UIElementSnapshot]) {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return
        }

        for child in children {
            guard elements.count < maxElements else { return }
            traverseElement(child, depth: depth + 1, maxDepth: maxDepth, elements: &elements)
        }
    }

    private static func collectText(_ element: AXUIElement, depth: Int, maxDepth: Int, texts: inout [String]) {
        guard depth < maxDepth else { return }

        let subrole = getStringAttribute(element, kAXSubroleAttribute) ?? ""
        if subrole == "AXSecureTextField" { return }

        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty, value.count > 1 {
            texts.append(value)
        } else if let title = getStringAttribute(element, kAXTitleAttribute), !title.isEmpty, title.count > 1 {
            texts.append(title)
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            collectText(child, depth: depth + 1, maxDepth: maxDepth, texts: &texts)
        }
    }

    // MARK: - Attribute Helpers

    private static func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func getPosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private static func getSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - Convenience

    /// Returns a text summary of the frontmost app's UI for injection into LLM context.
    static func summarizeFrontmostApp() -> String? {
        guard let snapshot = readFrontmostApp() else { return nil }
        return snapshot.summary()
    }
}

// MARK: - Data Models

struct AppSnapshot: Codable {
    let appName: String
    let pid: Int32
    let windowTitle: String
    let elements: [UIElementSnapshot]
    let timestamp: Date

    /// Returns a concise text summary for LLM context injection.
    func summary() -> String {
        var lines = ["App: \(appName) — Window: \(windowTitle)"]
        for el in elements.prefix(80) { // Cap at 80 elements to avoid token bloat
            let indent = String(repeating: "  ", count: min(el.depth, 4))
            var desc = "\(indent)[\(el.role)]"
            if !el.title.isEmpty { desc += " \"\(el.title)\"" }
            if !el.value.isEmpty && el.value != el.title {
                desc += " = \"\(el.value.prefix(100))\""
            }
            if !el.description.isEmpty && el.description != el.title {
                desc += " (\(el.description))"
            }
            lines.append(desc)
        }
        if elements.count > 80 {
            lines.append("... and \(elements.count - 80) more elements")
        }
        return lines.joined(separator: "\n")
    }
}

struct UIElementSnapshot: Codable {
    let role: String
    let subrole: String
    let title: String
    let value: String
    let description: String
    let label: String
    let identifier: String
    let position: CGPoint?
    let size: CGSize?
    let depth: Int

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, value, description, label, identifier, depth
        case posX, posY, width, height
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(subrole, forKey: .subrole)
        try c.encode(title, forKey: .title)
        try c.encode(value, forKey: .value)
        try c.encode(description, forKey: .description)
        try c.encode(label, forKey: .label)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(depth, forKey: .depth)
        try c.encodeIfPresent(position?.x, forKey: .posX)
        try c.encodeIfPresent(position?.y, forKey: .posY)
        try c.encodeIfPresent(size?.width, forKey: .width)
        try c.encodeIfPresent(size?.height, forKey: .height)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        subrole = try c.decode(String.self, forKey: .subrole)
        title = try c.decode(String.self, forKey: .title)
        value = try c.decode(String.self, forKey: .value)
        description = try c.decode(String.self, forKey: .description)
        label = try c.decode(String.self, forKey: .label)
        identifier = try c.decode(String.self, forKey: .identifier)
        depth = try c.decode(Int.self, forKey: .depth)
        let x = try c.decodeIfPresent(CGFloat.self, forKey: .posX)
        let y = try c.decodeIfPresent(CGFloat.self, forKey: .posY)
        position = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
        let w = try c.decodeIfPresent(CGFloat.self, forKey: .width)
        let h = try c.decodeIfPresent(CGFloat.self, forKey: .height)
        size = (w != nil && h != nil) ? CGSize(width: w!, height: h!) : nil
    }

    init(role: String, subrole: String, title: String, value: String, description: String,
         label: String, identifier: String, position: CGPoint?, size: CGSize?, depth: Int) {
        self.role = role; self.subrole = subrole; self.title = title; self.value = value
        self.description = description; self.label = label; self.identifier = identifier
        self.position = position; self.size = size; self.depth = depth
    }
}
