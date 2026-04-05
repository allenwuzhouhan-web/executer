import Cocoa
import ApplicationServices

// MARK: - AXUIElement Helpers

private func getFrontmostWindowElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var windowValue: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
        return nil
    }
    return (windowValue as! AXUIElement) // CFType cast always succeeds; nil handled by guard above
}

private func setWindowPosition(_ window: AXUIElement, x: CGFloat, y: CGFloat) {
    var point = CGPoint(x: x, y: y)
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
}

private func setWindowSize(_ window: AXUIElement, width: CGFloat, height: CGFloat) {
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
}

private func getScreenFrame() -> CGRect {
    let screen = NSScreen.main ?? NSScreen.screens.first!
    let visibleFrame = screen.visibleFrame
    // Convert from Cocoa (origin at bottom-left) to Carbon (origin at top-left)
    let screenFrame = screen.frame
    return CGRect(
        x: visibleFrame.origin.x,
        y: screenFrame.height - visibleFrame.origin.y - visibleFrame.height,
        width: visibleFrame.width,
        height: visibleFrame.height
    )
}

// MARK: - App-targeted window helper

private func getWindowElement(forApp appName: String) -> AXUIElement? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased() == appName.lowercased()
    }) else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var windowValue: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
          let windows = windowValue as? [AXUIElement], let first = windows.first else { return nil }
    return first
}

private func resolveWindow(appName: String?) -> AXUIElement? {
    if let name = appName {
        return getWindowElement(forApp: name) ?? getFrontmostWindowElement()
    }
    return getFrontmostWindowElement()
}

// MARK: - Tools

struct ListWindowsTool: ToolDefinition {
    let name = "list_windows"
    let description = "List all visible windows"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = windowList.compactMap { info -> String? in
            guard let name = info[kCGWindowOwnerName as String] as? String,
                  let title = info[kCGWindowName as String] as? String,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }
            return "\(name): \(title)"
        }
        return "Windows:\n\(windows.joined(separator: "\n"))"
    }
}

struct MoveWindowTool: ToolDefinition {
    let name = "move_window"
    let description = "Move the current window to a specific position"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "x": JSONSchema.integer(description: "X coordinate (pixels from left)"),
            "y": JSONSchema.integer(description: "Y coordinate (pixels from top)")
        ], required: ["x", "y"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let x = optionalInt("x", from: args), let y = optionalInt("y", from: args) else {
            throw ExecuterError.invalidArguments("x and y are required")
        }
        guard let window = getFrontmostWindowElement() else {
            return "No focused window found."
        }
        setWindowPosition(window, x: CGFloat(x), y: CGFloat(y))
        return "Moved window to (\(x), \(y))."
    }
}

struct ResizeWindowTool: ToolDefinition {
    let name = "resize_window"
    let description = "Resize the current window"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "width": JSONSchema.integer(description: "Width in pixels"),
            "height": JSONSchema.integer(description: "Height in pixels")
        ], required: ["width", "height"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let w = optionalInt("width", from: args), let h = optionalInt("height", from: args) else {
            throw ExecuterError.invalidArguments("width and height are required")
        }
        guard let window = getFrontmostWindowElement() else {
            return "No focused window found."
        }
        setWindowSize(window, width: CGFloat(w), height: CGFloat(h))
        return "Resized window to \(w)x\(h)."
    }
}

struct FullscreenWindowTool: ToolDefinition {
    let name = "fullscreen_window"
    let description = "Toggle fullscreen for a window. If app_name is given, switches to that app first then fullscreens it."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "App to fullscreen (e.g., 'Terminal', 'Safari'). If omitted, uses current window."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = optionalString("app_name", from: args)

        // Switch to target app first if specified
        if let name = appName, !name.isEmpty {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.lowercased() == name.lowercased()
            }) {
                app.activate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                return "App '\(name)' is not running."
            }
        }

        guard let window = getFrontmostWindowElement() else {
            return "No focused window found."
        }

        // Try AXFullScreen attribute
        var fullscreenValue: AnyObject?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue)
        let isFullscreen = (fullscreenValue as? Bool) ?? false
        let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!isFullscreen) as CFTypeRef)

        if result == .success {
            return isFullscreen ? "Exited fullscreen." : "Entered fullscreen."
        }

        // Fallback: press the fullscreen button (green traffic light)
        var buttonValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, "AXFullScreenButton" as CFString, &buttonValue) == .success,
           let bv = buttonValue {
            AXUIElementPerformAction(bv as! AXUIElement, kAXPressAction as CFString)
            return "Toggled fullscreen via zoom button."
        }

        return "Could not toggle fullscreen — app may not support it via accessibility."
    }
}

struct MinimizeWindowTool: ToolDefinition {
    let name = "minimize_window"
    let description = "Minimize the current window"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        guard let window = getFrontmostWindowElement() else {
            return "No focused window found."
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        return "Window minimized."
    }
}

struct TileWindowLeftTool: ToolDefinition {
    let name = "tile_window_left"
    let description = "Tile a window to the left half of the screen"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "Optional app name to target. If omitted, uses the frontmost window.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = optionalString("app_name", from: args)
        guard let window = resolveWindow(appName: appName) else { return "No focused window." }
        let frame = getScreenFrame()
        setWindowPosition(window, x: frame.origin.x, y: frame.origin.y)
        setWindowSize(window, width: frame.width / 2, height: frame.height)
        return "Tiled \(appName ?? "window") to left half."
    }
}

struct TileWindowRightTool: ToolDefinition {
    let name = "tile_window_right"
    let description = "Tile a window to the right half of the screen"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "Optional app name to target. If omitted, uses the frontmost window.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = optionalString("app_name", from: args)
        guard let window = resolveWindow(appName: appName) else { return "No focused window." }
        let frame = getScreenFrame()
        setWindowPosition(window, x: frame.origin.x + frame.width / 2, y: frame.origin.y)
        setWindowSize(window, width: frame.width / 2, height: frame.height)
        return "Tiled \(appName ?? "window") to right half."
    }
}

struct TileWindowTopLeftTool: ToolDefinition {
    let name = "tile_window_top_left"
    let description = "Tile a window to the top-left quarter of the screen"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "Optional app name to target. If omitted, uses the frontmost window.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = optionalString("app_name", from: args)
        guard let window = resolveWindow(appName: appName) else { return "No focused window." }
        let frame = getScreenFrame()
        setWindowPosition(window, x: frame.origin.x, y: frame.origin.y)
        setWindowSize(window, width: frame.width / 2, height: frame.height / 2)
        return "Tiled \(appName ?? "window") to top-left quarter."
    }
}

struct CenterWindowTool: ToolDefinition {
    let name = "center_window"
    let description = "Center the current window on screen"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        guard let window = getFrontmostWindowElement() else { return "No focused window." }
        let frame = getScreenFrame()

        // Get current window size
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        var windowSize = CGSize.zero
        if let axValue = sizeValue {
            AXValueGetValue(axValue as! AXValue, .cgSize, &windowSize)
        }

        let x = frame.origin.x + (frame.width - windowSize.width) / 2
        let y = frame.origin.y + (frame.height - windowSize.height) / 2
        setWindowPosition(window, x: x, y: y)
        return "Window centered."
    }
}

struct CloseWindowTool: ToolDefinition {
    let name = "close_window"
    let description = "Close the current window"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        guard let window = getFrontmostWindowElement() else { return "No focused window." }
        var closeButton: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton)
        if let button = closeButton {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return "Window closed."
        }
        return "Could not close window."
    }
}

// MARK: - Step 5: App-Targeted Window & Space Management

struct TileWindowsSideBySideTool: ToolDefinition {
    let name = "tile_windows_side_by_side"
    let description = "Tile two apps side by side (left and right halves of screen)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "left_app": JSONSchema.string(description: "Name of the app to tile on the left"),
            "right_app": JSONSchema.string(description: "Name of the app to tile on the right")
        ], required: ["left_app", "right_app"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let leftApp = try requiredString("left_app", from: args)
        let rightApp = try requiredString("right_app", from: args)

        let frame = getScreenFrame()

        // Activate and tile left app
        if let leftWindow = getWindowElement(forApp: leftApp) {
            setWindowPosition(leftWindow, x: frame.origin.x, y: frame.origin.y)
            setWindowSize(leftWindow, width: frame.width / 2, height: frame.height)
        } else {
            // Try to launch the app first
            NSWorkspace.shared.launchApplication(leftApp)
            try await Task.sleep(for: .milliseconds(500))
            if let leftWindow = getWindowElement(forApp: leftApp) {
                setWindowPosition(leftWindow, x: frame.origin.x, y: frame.origin.y)
                setWindowSize(leftWindow, width: frame.width / 2, height: frame.height)
            } else {
                return "Could not find window for '\(leftApp)'."
            }
        }

        // Activate and tile right app
        if let rightWindow = getWindowElement(forApp: rightApp) {
            setWindowPosition(rightWindow, x: frame.origin.x + frame.width / 2, y: frame.origin.y)
            setWindowSize(rightWindow, width: frame.width / 2, height: frame.height)
        } else {
            NSWorkspace.shared.launchApplication(rightApp)
            try await Task.sleep(for: .milliseconds(500))
            if let rightWindow = getWindowElement(forApp: rightApp) {
                setWindowPosition(rightWindow, x: frame.origin.x + frame.width / 2, y: frame.origin.y)
                setWindowSize(rightWindow, width: frame.width / 2, height: frame.height)
            } else {
                return "Could not find window for '\(rightApp)'."
            }
        }

        return "Tiled \(leftApp) (left) and \(rightApp) (right) side by side."
    }
}

struct MoveWindowToSpaceTool: ToolDefinition {
    let name = "move_window_to_space"
    let description = "Move a window to a specific Mission Control space/desktop"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "Optional app name to move. If omitted, moves the frontmost window."),
            "space_number": JSONSchema.integer(description: "The desktop/space number to move to (1-9)", minimum: 1, maximum: 9)
        ], required: ["space_number"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = optionalString("app_name", from: args)
        guard let spaceNum = optionalInt("space_number", from: args) else {
            throw ExecuterError.invalidArguments("space_number is required")
        }

        // Activate the target app if specified
        if let name = appName {
            let script = "tell application \"\(AppleScriptRunner.escape(name))\" to activate"
            AppleScriptRunner.run(script)
            try await Task.sleep(for: .milliseconds(300))
        }

        // Use ctrl+N keyboard shortcut to switch spaces (requires Mission Control shortcuts enabled)
        let script = """
        tell application "System Events"
            key code \(48 + spaceNum) using control down
        end tell
        """
        AppleScriptRunner.run(script)

        return "Moved \(appName ?? "window") to Space \(spaceNum)."
    }
}

struct ArrangeWindowsTool: ToolDefinition {
    let name = "arrange_windows"
    let description = "Arrange multiple app windows in a specific layout"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "layout": JSONSchema.enumString(description: "The layout arrangement", values: ["side_by_side", "cascade", "grid_2x2"]),
            "apps": JSONSchema.string(description: "Comma-separated list of app names to arrange")
        ], required: ["layout", "apps"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let layout = try requiredString("layout", from: args)
        let appsStr = try requiredString("apps", from: args)
        let appNames = appsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let frame = getScreenFrame()
        var arranged = 0

        switch layout {
        case "side_by_side":
            let width = frame.width / CGFloat(appNames.count)
            for (i, appName) in appNames.enumerated() {
                if let window = getWindowElement(forApp: appName) {
                    setWindowPosition(window, x: frame.origin.x + width * CGFloat(i), y: frame.origin.y)
                    setWindowSize(window, width: width, height: frame.height)
                    arranged += 1
                }
            }

        case "cascade":
            let offset: CGFloat = 30
            for (i, appName) in appNames.enumerated() {
                if let window = getWindowElement(forApp: appName) {
                    let x = frame.origin.x + offset * CGFloat(i)
                    let y = frame.origin.y + offset * CGFloat(i)
                    setWindowPosition(window, x: x, y: y)
                    setWindowSize(window, width: frame.width * 0.7, height: frame.height * 0.7)
                    arranged += 1
                }
            }

        case "grid_2x2":
            let halfW = frame.width / 2
            let halfH = frame.height / 2
            let positions: [(CGFloat, CGFloat)] = [
                (frame.origin.x, frame.origin.y),
                (frame.origin.x + halfW, frame.origin.y),
                (frame.origin.x, frame.origin.y + halfH),
                (frame.origin.x + halfW, frame.origin.y + halfH),
            ]
            for (i, appName) in appNames.prefix(4).enumerated() {
                if let window = getWindowElement(forApp: appName) {
                    setWindowPosition(window, x: positions[i].0, y: positions[i].1)
                    setWindowSize(window, width: halfW, height: halfH)
                    arranged += 1
                }
            }

        default:
            throw ExecuterError.invalidArguments("Unknown layout: \(layout)")
        }

        return "Arranged \(arranged)/\(appNames.count) windows in \(layout) layout."
    }
}
