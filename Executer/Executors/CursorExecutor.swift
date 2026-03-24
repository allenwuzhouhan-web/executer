import Cocoa
import CoreGraphics

// MARK: - Move Cursor

struct MoveCursorTool: ToolDefinition {
    let name = "move_cursor"
    let description = "Move the mouse cursor to a specific screen position. Animates smoothly."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.number(description: "X coordinate (pixels from left edge)"),
            "y": JSONSchema.number(description: "Y coordinate (pixels from top edge)"),
        ], required: ["x", "y"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let targetX = try requiredDouble("x", from: args)
        let targetY = try requiredDouble("y", from: args)
        let target = CGPoint(x: targetX, y: targetY)

        // Smooth animation: move in steps over ~200ms
        let current = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        // Convert NS coordinates (bottom-left origin) to CG coordinates (top-left origin)
        let startCG = CGPoint(x: current.x, y: screenHeight - current.y)

        let steps = 20
        let duration: Double = 0.2
        let stepDelay = duration / Double(steps)

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            // Ease-out curve for natural deceleration
            let ease = 1 - pow(1 - t, 3)
            let x = startCG.x + (target.x - startCG.x) * ease
            let y = startCG.y + (target.y - startCG.y) * ease
            let point = CGPoint(x: x, y: y)

            CGWarpMouseCursorPosition(point)

            // Post a mouseMoved event so apps track the cursor
            if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }

            try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
        }

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

    private func findElementViaAccessibility(matching text: String) -> CGPoint? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowValue: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard let window = windowValue else { return nil }

        // Search for UI element matching text
        return searchElement(window as! AXUIElement, for: text)
    }

    private func searchElement(_ element: AXUIElement, for text: String, depth: Int = 0) -> CGPoint? {
        guard depth < 10 else { return nil } // Prevent infinite recursion

        // Check this element's title/value/description
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, attr as CFString, &value)
            if let str = value as? String, str.lowercased().contains(text) {
                // Get position and size
                var posValue: AnyObject?
                var sizeValue: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

                if let posValue = posValue, let sizeValue = sizeValue {
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                    // Return center
                    return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                }
            }
        }

        // Recurse into children
        var childrenValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = searchElement(child, for: text, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
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
