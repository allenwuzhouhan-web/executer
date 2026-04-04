import Cocoa
import CoreGraphics

// MARK: - AI Cursor Activation Helper

/// Ensures AICursorManager is active whenever any cursor tool fires,
/// so the purple cursor + trail + banner show even outside ComputerUseAgent.
private func ensureAICursorActive() {
    if !AICursorManager.shared.isActive {
        DispatchQueue.main.async {
            AICursorManager.shared.startAIControl()
        }
    }
}

// MARK: - Move Cursor

struct MoveCursorTool: ToolDefinition {
    let name = "move_cursor"
    let description = "Move the mouse cursor to a specific screen position. Animates smoothly."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.number(description: "X coordinate (pixels from left edge)"),
            "y": JSONSchema.number(description: "Y coordinate (pixels from top edge)"),
            "speed": JSONSchema.string(description: "Movement speed: 'instant', 'fast', 'normal' (default), 'slow'"),
        ], required: ["x", "y"])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActive()
        let args = try parseArguments(arguments)
        let targetX = try requiredDouble("x", from: args)
        let targetY = try requiredDouble("y", from: args)
        let target = CGPoint(x: targetX, y: targetY)
        let speed = optionalString("speed", from: args)

        let config = SmoothMouseDriver.configFromSpeed(speed)
        try await SmoothMouseDriver.shared.moveTo(target, config: config)

        return "Cursor moved to (\(Int(targetX)), \(Int(targetY)))."
    }
}

// MARK: - Click

struct ClickTool: ToolDefinition {
    let name = "click"
    let description = "Click at a position (defaults to current cursor location). Supports left/right click and double-click."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.number(description: "X coordinate (optional — uses current position if omitted)"),
            "y": JSONSchema.number(description: "Y coordinate (optional — uses current position if omitted)"),
            "button": JSONSchema.string(description: "Mouse button: 'left' (default) or 'right'"),
            "count": JSONSchema.integer(description: "Click count: 1 for single (default), 2 for double-click"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActive()
        let args = try parseArguments(arguments)
        let button = optionalString("button", from: args) ?? "left"
        let count = optionalInt("count", from: args) ?? 1

        let position: CGPoint
        if let x = optionalDouble("x", from: args), let y = optionalDouble("y", from: args) {
            position = CGPoint(x: x, y: y)
            // Move cursor to target first
            CGWarpMouseCursorPosition(position)
            try await Task.sleep(nanoseconds: 30_000_000) // 30ms settle
        } else {
            let nsPos = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 900
            position = CGPoint(x: nsPos.x, y: screenHeight - nsPos.y)
        }

        let source = CGEventSource(stateID: .hidSystemState)

        let isRight = button == "right"
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = isRight ? .right : .left

        for click in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                     mouseCursorPosition: position, mouseButton: mouseButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: position, mouseButton: mouseButton) else {
                return "Failed to create click event."
            }

            // Set click count for double/triple click detection by apps
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))

            down.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms between down and up
            up.post(tap: .cghidEventTap)

            if click < count {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms between clicks
            }
        }

        // Invalidate perception cache — screen state changed after click
        VisionEngine.shared.invalidateCache()

        let clickDesc = count > 1 ? "Double-clicked" : (isRight ? "Right-clicked" : "Clicked")
        return "\(clickDesc) at (\(Int(position.x)), \(Int(position.y)))."
    }
}

// MARK: - Click Element (OCR-guided)

struct ClickElementTool: ToolDefinition {
    let name = "click_element"
    let description = "Find a UI element on screen by its text/label and click it. Uses OCR to locate the element."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "description": JSONSchema.string(description: "Text or label of the element to click (e.g., 'Send', 'Cancel', 'Search')"),
        ], required: ["description"])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActive()
        let args = try parseArguments(arguments)
        let target = try requiredString("description", from: args).lowercased()

        // Try accessibility first — it's faster and gives exact positions
        if let pos = findElementViaAccessibility(matching: target) {
            let clickArgs = "{\"x\": \(Int(pos.x)), \"y\": \(Int(pos.y))}"
            let clickResult = try await ClickTool().execute(arguments: clickArgs)
            return "Found '\(target)' via accessibility. \(clickResult)"
        }

        // Fallback: AppleScript UI scripting for common button clicks
        let escaped = target.replacingOccurrences(of: "'", with: "\\'")
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            let script = """
            tell application "System Events"
                tell process "\(frontApp)"
                    click (first button whose name contains "\(escaped)" or description contains "\(escaped)")
                end tell
            end tell
            """
            if let _ = AppleScriptRunner.run(script) {
                return "Clicked '\(target)' in \(frontApp)."
            }
        }

        return "Could not find '\(target)' on screen. Try being more specific or use `click` with coordinates."
    }

    /// Finds a clickable element by text, reusing the shared ScreenReader snapshot
    /// instead of performing a separate AX tree walk.
    private func findElementViaAccessibility(matching text: String) -> CGPoint? {
        guard let snapshot = ScreenReader.readFrontmostApp() else { return nil }

        // Score all matching elements
        let scored: [(CGPoint, Int)] = snapshot.elements.compactMap { el in
            // Check all text fields for a match
            let fields = [el.title, el.value, el.description, el.label]
            guard fields.contains(where: { $0.lowercased().contains(text) }) else { return nil }

            guard let pos = el.position, let size = el.size else { return nil }
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)

            var score = 0
            if ScreenReader.isInteractiveRole(el.role) { score += 100 }
            // Exact text match
            let matchedField = fields.first { $0.lowercased().contains(text) } ?? ""
            if matchedField.lowercased().trimmingCharacters(in: .whitespaces) == text { score += 50 }
            // Smaller = more specific
            let area = size.width * size.height
            if area > 0 && area < 50000 { score += 30 }
            else if area > 0 && area < 150000 { score += 15 }
            if area <= 0 { score -= 50 }

            return (center, score)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0
    }
}

// MARK: - Scroll

struct ScrollTool: ToolDefinition {
    let name = "scroll"
    let description = "Scroll the screen in a direction"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "direction": JSONSchema.string(description: "Scroll direction: 'up', 'down', 'left', or 'right'"),
            "amount": JSONSchema.integer(description: "Scroll amount 1-10 (default 3)"),
        ], required: ["direction"])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActive()
        let args = try parseArguments(arguments)
        let direction = try requiredString("direction", from: args).lowercased()
        let amount = optionalInt("amount", from: args) ?? 3

        let scrollUnit = Int32(amount * 5) // Each unit = ~5 pixels of scroll

        // Scroll in steps for smoothness
        let steps = amount
        for _ in 0..<steps {
            let source = CGEventSource(stateID: .hidSystemState)

            var deltaY: Int32 = 0
            var deltaX: Int32 = 0

            switch direction {
            case "up": deltaY = scrollUnit / Int32(steps)
            case "down": deltaY = -(scrollUnit / Int32(steps))
            case "left": deltaX = scrollUnit / Int32(steps)
            case "right": deltaX = -(scrollUnit / Int32(steps))
            default: return "Invalid direction. Use 'up', 'down', 'left', or 'right'."
            }

            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                   wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
                event.post(tap: CGEventTapLocation.cghidEventTap)
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms between scroll steps
        }

        return "Scrolled \(direction)."
    }
}

// MARK: - Drag

struct DragTool: ToolDefinition {
    let name = "drag"
    let description = "Drag from one position to another (click-hold-move-release)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "from_x": JSONSchema.number(description: "Start X coordinate"),
            "from_y": JSONSchema.number(description: "Start Y coordinate"),
            "to_x": JSONSchema.number(description: "End X coordinate"),
            "to_y": JSONSchema.number(description: "End Y coordinate"),
        ], required: ["from_x", "from_y", "to_x", "to_y"])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActive()
        let args = try parseArguments(arguments)
        let fromX = try requiredDouble("from_x", from: args)
        let fromY = try requiredDouble("from_y", from: args)
        let toX = try requiredDouble("to_x", from: args)
        let toY = try requiredDouble("to_y", from: args)

        let from = CGPoint(x: fromX, y: fromY)
        let to = CGPoint(x: toX, y: toY)
        let source = CGEventSource(stateID: .hidSystemState)

        // Move to start
        CGWarpMouseCursorPosition(from)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Mouse down
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                              mouseCursorPosition: from, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Drag in steps
        let steps = 25
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let ease = 1 - pow(1 - t, 2) // ease-out
            let x = from.x + (to.x - from.x) * ease
            let y = from.y + (to.y - from.y) * ease
            let pos = CGPoint(x: x, y: y)

            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                  mouseCursorPosition: pos, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            if AICursorManager.shared.isActive {
                AICursorManager.shared.addTrailPoint(pos)
            }
            try await Task.sleep(nanoseconds: 12_000_000) // ~300ms total
        }

        // Mouse up
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: to, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }

        return "Dragged from (\(Int(fromX)),\(Int(fromY))) to (\(Int(toX)),\(Int(toY)))."
    }
}

// MARK: - Get Cursor Position

struct GetCursorPositionTool: ToolDefinition {
    let name = "get_cursor_position"
    let description = "Get the current mouse cursor position"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let nsPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let cgX = Int(nsPos.x)
        let cgY = Int(screenHeight - nsPos.y)
        return "Cursor at (\(cgX), \(cgY))."
    }
}
