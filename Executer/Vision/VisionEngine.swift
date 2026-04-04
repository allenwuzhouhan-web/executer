import Foundation
import CoreGraphics
import AppKit

/// Unified screen perception: fuses AX tree + screenshot + OCR into a single representation.
/// AX tree is primary (instant, structured). Screenshot+OCR is backup for poor accessibility apps.
class VisionEngine {
    static let shared = VisionEngine()

    // MARK: - Data Models

    struct ScreenPerception {
        let appName: String
        let windowTitle: String
        let elements: [PerceptualElement]
        let axSucceeded: Bool
        let ocrText: String?
        let screenshotBase64: String?
        let timestamp: Date
        let contentHash: UInt64
        /// Focused app PID for tracking app switches between actions.
        let focusedPID: pid_t?
    }

    struct PerceptualElement {
        let id: String
        let role: String
        let label: String
        let value: String
        let clickPoint: CGPoint?
        let bounds: CGRect?
        let isInteractive: Bool
        let depth: Int
        /// Parent element ID for hierarchical references (nil for top-level).
        let parentID: String?
    }

    // MARK: - Perception Cache

    private var lastPerception: ScreenPerception?
    private var lastPerceptionTime: Date = .distantPast
    /// Cache TTL for full perception results (default 200ms — one perception per action).
    var perceptionCacheTTL: TimeInterval = 0.2

    /// Force the next `perceive()` to do a fresh read (call after UI actions).
    func invalidateCache() {
        lastPerception = nil
        ScreenReader.invalidateCache()
    }

    // MARK: - Perception

    /// Full perception: AX tree first, screenshot+OCR fallback if AX is insufficient.
    /// Returns cached result if within TTL (avoids redundant AX walks within a single action cycle).
    func perceive(forceScreenshot: Bool = false) async -> ScreenPerception {
        // Return cache if fresh and no screenshot forced
        if !forceScreenshot, let cached = lastPerception,
           Date().timeIntervalSince(lastPerceptionTime) < perceptionCacheTTL {
            return cached
        }

        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Try AX tree first
        let axResult = tryAXPerception()
        let axElements = axResult?.elements ?? []
        let axSufficient = axResult?.sufficient ?? false

        var ocrText: String? = nil
        var screenshotBase64: String? = nil

        // Fall back to screenshot+OCR if AX is insufficient or forced
        if forceScreenshot || !axSufficient {
            if let cgImage = ScreenCapture.captureMainDisplay() {
                screenshotBase64 = ScreenCapture.toBase64(cgImage, maxWidth: 1024)

                if let ocrResults = try? await OCRService.recognize(image: cgImage) {
                    let fused = fuseAXAndOCR(ax: axElements, ocr: ocrResults, imageWidth: cgImage.width, imageHeight: cgImage.height)
                    ocrText = ocrResults.map { $0.text }.joined(separator: " ")

                    let appName = axResult?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
                    let windowTitle = axResult?.windowTitle ?? ""

                    let perception = ScreenPerception(
                        appName: appName, windowTitle: windowTitle,
                        elements: fused, axSucceeded: axSufficient,
                        ocrText: ocrText, screenshotBase64: screenshotBase64,
                        timestamp: Date(), contentHash: contentHash(for: fused),
                        focusedPID: currentPID
                    )
                    lastPerception = perception
                    lastPerceptionTime = Date()
                    return perception
                }
            }
        }

        let appName = axResult?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let windowTitle = axResult?.windowTitle ?? ""

        let perception = ScreenPerception(
            appName: appName, windowTitle: windowTitle,
            elements: axElements, axSucceeded: axSufficient,
            ocrText: ocrText, screenshotBase64: screenshotBase64,
            timestamp: Date(), contentHash: contentHash(for: axElements),
            focusedPID: currentPID
        )
        lastPerception = perception
        lastPerceptionTime = Date()
        return perception
    }

    /// Text-only perception for LLM context injection.
    func perceiveAsText(maxElements: Int = 120) async -> String {
        let perception = await perceive()
        return formatPerception(perception, maxElements: maxElements)
    }

    /// Check if screen changed since last perception. Also detects app switches.
    func detectChanges(from previous: ScreenPerception) -> Bool {
        // App switch is always a change
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if currentPID != previous.focusedPID { return true }

        let current = tryAXPerception()
        let currentHash = contentHash(for: current?.elements ?? [])
        return currentHash != previous.contentHash
    }

    /// Verify that a UI action had an effect by checking for specific changes.
    /// Returns a description of what changed, or nil if nothing changed.
    func verifyActionEffect(before: ScreenPerception, expectedChange: String? = nil) async -> String? {
        invalidateCache()
        let after = await perceive()

        // Check for app switch
        if after.appName != before.appName {
            return "App switched from \(before.appName) to \(after.appName)"
        }

        // Check for window title change
        if after.windowTitle != before.windowTitle {
            return "Window changed: \(before.windowTitle) → \(after.windowTitle)"
        }

        // Check for element count change (new dialog, menu, etc.)
        let beforeInteractive = before.elements.filter { $0.isInteractive }.count
        let afterInteractive = after.elements.filter { $0.isInteractive }.count
        if abs(afterInteractive - beforeInteractive) > 3 {
            let delta = afterInteractive - beforeInteractive
            return delta > 0 ? "New UI appeared (+\(delta) interactive elements)" : "UI elements removed (\(delta))"
        }

        // Check content hash
        if after.contentHash != before.contentHash {
            return "Screen content changed"
        }

        return nil
    }

    // MARK: - AX Perception

    private struct AXResult {
        let appName: String
        let windowTitle: String
        let elements: [PerceptualElement]
        let sufficient: Bool
    }

    private func tryAXPerception() -> AXResult? {
        guard let snapshot = ScreenReader.readFrontmostApp() else { return nil }

        // Build parent IDs: elements at depth N are parented by the last element at depth N-1
        var parentStack: [(depth: Int, id: String)] = []

        let elements = snapshot.elements.map { el -> PerceptualElement in
            let bestLabel = [el.title, el.description, el.label, el.value]
                .first(where: { !$0.isEmpty }) ?? ""

            let clickPoint: CGPoint?
            if let pos = el.position, let size = el.size {
                clickPoint = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            } else {
                clickPoint = nil
            }

            let bounds: CGRect?
            if let pos = el.position, let size = el.size {
                bounds = CGRect(origin: pos, size: size)
            } else {
                bounds = nil
            }

            let id = stableID(role: el.role, label: bestLabel, position: clickPoint)

            // Find parent: pop stack until we find a depth < current
            while let last = parentStack.last, last.depth >= el.depth {
                parentStack.removeLast()
            }
            let parentID = parentStack.last?.id
            parentStack.append((depth: el.depth, id: id))

            return PerceptualElement(
                id: id,
                role: el.role,
                label: bestLabel,
                value: el.value,
                clickPoint: clickPoint,
                bounds: bounds,
                isInteractive: ScreenReader.isInteractiveRole(el.role),
                depth: el.depth,
                parentID: parentID
            )
        }

        let interactiveCount = elements.filter { $0.isInteractive }.count
        let sufficient = interactiveCount >= 5

        return AXResult(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            elements: elements,
            sufficient: sufficient
        )
    }

    // MARK: - OCR Fusion

    private func fuseAXAndOCR(
        ax: [PerceptualElement],
        ocr: [OCRService.OCRResult],
        imageWidth: Int,
        imageHeight: Int
    ) -> [PerceptualElement] {
        var merged = ax

        for ocrResult in ocr {
            let screenRect = OCRService.toScreenCoordinates(
                ocrResult.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight
            )
            let center = CGPoint(x: screenRect.midX, y: screenRect.midY)

            // Skip if this OCR text overlaps with an existing AX element
            let overlaps = ax.contains { el in
                guard let elBounds = el.bounds else { return false }
                return elBounds.intersects(screenRect)
            }

            if !overlaps && ocrResult.confidence > 0.5 {
                let id = stableID(role: "OCRText", label: ocrResult.text, position: center)
                merged.append(PerceptualElement(
                    id: id,
                    role: "OCRText",
                    label: ocrResult.text,
                    value: "",
                    clickPoint: center,
                    bounds: screenRect,
                    isInteractive: false,
                    depth: 0,
                    parentID: nil
                ))
            }
        }

        return merged
    }

    // MARK: - Formatting

    func formatPerception(_ perception: ScreenPerception, maxElements: Int = 120) -> String {
        var lines: [String] = []
        lines.append("Screen: \(perception.appName) — \(perception.windowTitle)")
        lines.append("---")

        // Build a lookup for parent labels (for hierarchy context)
        let elementByID = Dictionary(perception.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Interactive elements first (the ones the agent can act on)
        let interactive = perception.elements.filter { $0.isInteractive }
        let textElements = perception.elements.filter { !$0.isInteractive && !$0.label.isEmpty }

        for el in interactive.prefix(maxElements) {
            let pos = el.clickPoint.map { "at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
            let val = el.value.isEmpty ? "" : " = \"\(String(el.value.prefix(60)))\""
            // Show parent context for disambiguation (e.g., "in Toolbar")
            var context = ""
            if let pid = el.parentID, let parent = elementByID[pid], !parent.label.isEmpty {
                context = " in \"\(String(parent.label.prefix(30)))\""
            }
            lines.append("[\(el.id)] \(el.role) \"\(String(el.label.prefix(80)))\"\(val)\(context) \(pos)")
        }

        let remaining = maxElements - interactive.count
        if remaining > 0 && !textElements.isEmpty {
            lines.append("--- Text ---")
            for el in textElements.prefix(remaining) {
                let pos = el.clickPoint.map { "at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
                lines.append("\"\(String(el.label.prefix(100)))\" \(pos)")
            }
        }

        if perception.elements.count > maxElements {
            lines.append("... and \(perception.elements.count - maxElements) more elements")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func stableID(role: String, label: String, position: CGPoint?) -> String {
        let posStr = position.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?"
        let raw = "\(role):\(label.prefix(30)):\(posStr)"
        // Simple hash to short ID
        var hash: UInt64 = 5381
        for byte in raw.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "e%04x", hash & 0xFFFF)
    }

    private func contentHash(for elements: [PerceptualElement]) -> UInt64 {
        var hash: UInt64 = 5381
        for el in elements {
            for byte in el.label.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            if let p = el.clickPoint {
                hash = ((hash << 5) &+ hash) &+ UInt64(Int(p.x))
                hash = ((hash << 5) &+ hash) &+ UInt64(Int(p.y))
            }
        }
        return hash
    }
}

// MARK: - Perceive Screen Tools

struct PerceiveScreenTool: ToolDefinition {
    let name = "perceive_screen"
    let description = "Read the current screen state using accessibility APIs (fast, structured). Returns interactive elements with their positions for clicking. Falls back to OCR if accessibility is insufficient."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "max_elements": JSONSchema.integer(description: "Maximum elements to return (default 120)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let maxElements = optionalInt("max_elements", from: args) ?? 120
        return await VisionEngine.shared.perceiveAsText(maxElements: maxElements)
    }
}

struct PerceiveScreenVisualTool: ToolDefinition {
    let name = "perceive_screen_visual"
    let description = "Read the current screen state with both structured data and a screenshot. The screenshot is sent as a base64 PNG for visual analysis. Use this when you need to see the actual screen (images, layouts, colors)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let perception = await VisionEngine.shared.perceive(forceScreenshot: true)
        var text = VisionEngine.shared.formatPerception(perception)

        if let base64 = perception.screenshotBase64 {
            text += "\n\n[SCREENSHOT attached as base64 PNG, \(base64.count / 1024)KB]"
        }

        return text
    }
}

// MARK: - Find Element Tool

struct FindElementTool: ToolDefinition {
    let name = "find_element"
    let description = """
        Search the current screen for a specific UI element by text, role, or location. \
        Faster than perceive_screen when you know what you're looking for. Returns matching \
        elements with their click coordinates. Use this before clicking to find exact positions.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "Text to search for in element labels, values, and descriptions (fuzzy match)"),
            "role": JSONSchema.string(description: "Filter by AX role (e.g., 'AXButton', 'AXTextField', 'AXLink', 'AXMenuItem')"),
            "near_x": JSONSchema.integer(description: "Search near this X coordinate (within 200px radius)"),
            "near_y": JSONSchema.integer(description: "Search near this Y coordinate (within 200px radius)"),
            "interactive_only": JSONSchema.boolean(description: "Only return interactive/clickable elements (default true)"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = optionalString("text", from: args)?.lowercased()
        let role = optionalString("role", from: args)
        let nearX = optionalInt("near_x", from: args)
        let nearY = optionalInt("near_y", from: args)
        let interactiveOnly = (args["interactive_only"] as? Bool) ?? true

        let perception = await VisionEngine.shared.perceive()

        var matches = perception.elements

        // Filter by text
        if let text = text {
            matches = matches.filter { el in
                el.label.lowercased().contains(text) || el.value.lowercased().contains(text)
            }
        }

        // Filter by role
        if let role = role {
            matches = matches.filter { $0.role == role }
        }

        // Filter by interactive
        if interactiveOnly {
            matches = matches.filter { $0.isInteractive }
        }

        // Filter by proximity
        if let x = nearX, let y = nearY {
            let center = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let radius: CGFloat = 200
            matches = matches.filter { el in
                guard let pt = el.clickPoint else { return false }
                let dx = pt.x - center.x
                let dy = pt.y - center.y
                return (dx * dx + dy * dy) <= (radius * radius)
            }
        }

        if matches.isEmpty {
            var desc = "No elements found"
            if let text = text { desc += " matching '\(text)'" }
            if let role = role { desc += " with role \(role)" }
            return desc + ". Try perceive_screen for full view."
        }

        // Format results (max 20)
        var lines = ["Found \(matches.count) element(s):"]
        for el in matches.prefix(20) {
            let pos = el.clickPoint.map { "at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
            let val = el.value.isEmpty ? "" : " = \"\(String(el.value.prefix(40)))\""
            lines.append("[\(el.id)] \(el.role) \"\(String(el.label.prefix(60)))\"\(val) \(pos)")
        }
        if matches.count > 20 {
            lines.append("... and \(matches.count - 20) more")
        }
        return lines.joined(separator: "\n")
    }
}
