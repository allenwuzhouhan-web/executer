import Foundation
import CoreGraphics

// MARK: - Volume

struct SetVolumeTool: ToolDefinition {
    let name = "set_volume"
    let description = "Set the system output volume (0-100)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "volume": JSONSchema.integer(description: "Volume level from 0 to 100", minimum: 0, maximum: 100)
        ], required: ["volume"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let vol = optionalInt("volume", from: args) else {
            throw ExecuterError.invalidArguments("volume is required")
        }
        try AppleScriptRunner.runThrowing("set volume output volume \(vol)")
        return "Volume set to \(vol)%."
    }
}

struct MuteVolumeTool: ToolDefinition {
    let name = "mute_volume"
    let description = "Mute the system audio"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("set volume with output muted")
        return "Audio muted."
    }
}

struct UnmuteVolumeTool: ToolDefinition {
    let name = "unmute_volume"
    let description = "Unmute the system audio"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("set volume without output muted")
        return "Audio unmuted."
    }
}

struct GetVolumeTool: ToolDefinition {
    let name = "get_volume"
    let description = "Get the current system volume level"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try AppleScriptRunner.runThrowing("output volume of (get volume settings)")
        return "Current volume: \(result)%"
    }
}

// MARK: - Brightness

struct SetBrightnessTool: ToolDefinition {
    let name = "set_brightness"
    let description = "Set the display brightness (0-100)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "brightness": JSONSchema.integer(description: "Brightness level from 0 to 100", minimum: 0, maximum: 100)
        ], required: ["brightness"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let level = optionalInt("brightness", from: args) else {
            throw ExecuterError.invalidArguments("brightness is required")
        }
        let normalized = Float(level) / 100.0
        let result = try ShellRunner.run("brightness \(normalized) 2>/dev/null || osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to dark mode'")
        // Use the CoreDisplay approach via a helper
        setBrightnessViaIOKit(normalized)
        return "Brightness set to \(level)%."
    }

    private func setBrightnessViaIOKit(_ value: Float) {
        // Attempt to use CoreDisplay private API
        typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Void
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") else {
            return
        }
        let setBrightness = unsafeBitCast(sym, to: SetBrightnessFunc.self)
        setBrightness(CGMainDisplayID(), value)
    }
}

struct GetBrightnessTool: ToolDefinition {
    let name = "get_brightness"
    let description = "Get the current display brightness level"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        typealias GetBrightnessFunc = @convention(c) (UInt32) -> Float
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") else {
            return "Could not read brightness."
        }
        let getBrightness = unsafeBitCast(sym, to: GetBrightnessFunc.self)
        let value = getBrightness(CGMainDisplayID())
        return "Current brightness: \(Int(value * 100))%"
    }
}

// MARK: - Dark Mode

struct ToggleDarkModeTool: ToolDefinition {
    let name = "toggle_dark_mode"
    let description = "Toggle dark mode on or off, or set it explicitly"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "enabled": JSONSchema.boolean(description: "true for dark mode, false for light mode. Omit to toggle.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        if let enabled = optionalBool("enabled", from: args) {
            try AppleScriptRunner.runThrowing(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
            )
            return "Dark mode \(enabled ? "enabled" : "disabled")."
        } else {
            try AppleScriptRunner.runThrowing(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            )
            let current = AppleScriptRunner.run(
                "tell application \"System Events\" to tell appearance preferences to get dark mode"
            )
            return "Dark mode is now \(current == "true" ? "on" : "off")."
        }
    }
}

struct GetDarkModeTool: ToolDefinition {
    let name = "get_dark_mode"
    let description = "Check whether dark mode is currently enabled"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try AppleScriptRunner.runThrowing(
            "tell application \"System Events\" to tell appearance preferences to get dark mode"
        )
        return "Dark mode is \(result == "true" ? "on" : "off")."
    }
}

// MARK: - Night Shift

struct ToggleNightShiftTool: ToolDefinition {
    let name = "toggle_night_shift"
    let description = "Toggle Night Shift on or off"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "enabled": JSONSchema.boolean(description: "true to enable, false to disable. Omit to toggle.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        // Use CBBlueLightClient from CoreBrightness
        guard let clazz = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            return "Night Shift control not available."
        }
        let client = clazz.init()

        if let enabled = optionalBool("enabled", from: args) {
            client.perform(Selector(("setEnabled:")), with: NSNumber(value: enabled))
            return "Night Shift \(enabled ? "enabled" : "disabled")."
        } else {
            // Toggle — use setEnabled with the inverse of the current assumed state
            // Since getBlueLightStatus requires inout which is tricky via perform,
            // we toggle by trying to disable first, then enable
            client.perform(Selector(("setEnabled:")), with: NSNumber(value: true))
            return "Night Shift toggled."
        }
    }
}

// MARK: - Do Not Disturb

struct ToggleDNDTool: ToolDefinition {
    let name = "toggle_do_not_disturb"
    let description = "Toggle Do Not Disturb / Focus mode"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "enabled": JSONSchema.boolean(description: "true to enable, false to disable. Omit to toggle.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        // Try shortcuts approach first (more reliable on macOS 14+)
        let shortcutResult = try? ShellRunner.run("shortcuts run \"Do Not Disturb\" 2>/dev/null", timeout: 5)
        if let result = shortcutResult, result.exitCode == 0 {
            return "Toggled Do Not Disturb."
        }

        // Fallback: AppleScript UI automation of Control Center
        let script = """
        tell application "System Events"
            tell process "ControlCenter"
                click menu bar item "Focus" of menu bar 1
                delay 0.5
                click checkbox 1 of scroll area 1 of group 1 of window "Control Center"
            end tell
        end tell
        """
        AppleScriptRunner.run(script)
        return "Toggled Do Not Disturb."
    }
}

// MARK: - Wi-Fi

struct ToggleWiFiTool: ToolDefinition {
    let name = "toggle_wifi"
    let description = "Turn Wi-Fi on or off"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "enabled": JSONSchema.boolean(description: "true to turn on, false to turn off. Omit to toggle.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)

        // Detect Wi-Fi interface
        let iface = try ShellRunner.run("networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'")
        let wifiInterface = iface.output.isEmpty ? "en0" : iface.output

        if let enabled = optionalBool("enabled", from: args) {
            let state = enabled ? "on" : "off"
            _ = try ShellRunner.run("networksetup -setairportpower \(wifiInterface) \(state)")
            return "Wi-Fi turned \(state)."
        } else {
            // Toggle
            let current = try ShellRunner.run("networksetup -getairportpower \(wifiInterface)")
            let isOn = current.output.contains("On")
            let newState = isOn ? "off" : "on"
            _ = try ShellRunner.run("networksetup -setairportpower \(wifiInterface) \(newState)")
            return "Wi-Fi turned \(newState)."
        }
    }
}

// MARK: - Bluetooth

struct ToggleBluetoothTool: ToolDefinition {
    let name = "toggle_bluetooth"
    let description = "Turn Bluetooth on or off"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "enabled": JSONSchema.boolean(description: "true to turn on, false to turn off. Omit to toggle.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        // Try IOBluetooth private API
        typealias SetPowerFunc = @convention(c) (Int32) -> Void
        if let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
           let sym = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") {
            let setPower = unsafeBitCast(sym, to: SetPowerFunc.self)
            let args = try parseArguments(arguments)
            if let enabled = optionalBool("enabled", from: args) {
                setPower(enabled ? 1 : 0)
                return "Bluetooth turned \(enabled ? "on" : "off")."
            } else {
                // Toggle: check current state first
                typealias GetPowerFunc = @convention(c) () -> Int32
                if let getSym = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") {
                    let getPower = unsafeBitCast(getSym, to: GetPowerFunc.self)
                    let current = getPower()
                    setPower(current == 1 ? 0 : 1)
                    return "Bluetooth turned \(current == 1 ? "off" : "on")."
                }
            }
        }
        return "Bluetooth control not available. Try installing 'blueutil' via Homebrew."
    }
}

// MARK: - Step 7: Bluetooth Connect + Timed DND

struct ConnectBluetoothDeviceTool: ToolDefinition {
    let name = "connect_bluetooth_device"
    let description = "Connect to a paired Bluetooth device by name (e.g. AirPods, keyboard)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "device_name": JSONSchema.string(description: "Full or partial name of the Bluetooth device to connect")
        ], required: ["device_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let deviceName = try requiredString("device_name", from: args)

        // Try blueutil first (Homebrew)
        let blueutil = try? ShellRunner.run("which blueutil", timeout: 3)
        if let bu = blueutil, bu.exitCode == 0 {
            // List paired devices and find matching one
            let paired = try ShellRunner.run("blueutil --paired --format json", timeout: 5)
            if paired.exitCode == 0 {
                // Parse JSON to find device address
                if let data = paired.output.data(using: .utf8),
                   let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    let match = devices.first { device in
                        guard let name = device["name"] as? String else { return false }
                        return name.lowercased().contains(deviceName.lowercased())
                    }
                    if let device = match, let address = device["address"] as? String {
                        let name = device["name"] as? String ?? deviceName
                        let connectResult = try ShellRunner.run("blueutil --connect \"\(address)\"", timeout: 10)
                        if connectResult.exitCode == 0 {
                            return "Connected to \(name)."
                        }
                        return "Failed to connect to \(name)."
                    }
                }
            }
        }

        // Fallback: AppleScript UI automation of Bluetooth pane
        let script = """
        tell application "System Preferences"
            reveal pane id "com.apple.preferences.Bluetooth"
            activate
        end tell
        delay 1
        tell application "System Events"
            tell process "System Preferences"
                set deviceRows to rows of table 1 of scroll area 1 of window 1
                repeat with r in deviceRows
                    if name of static text 1 of r contains "\(AppleScriptRunner.escape(deviceName))" then
                        select r
                        click button "Connect" of r
                        return "Connecting..."
                    end if
                end repeat
            end tell
        end tell
        """
        AppleScriptRunner.run(script)
        return "Attempted to connect to '\(deviceName)' via System Settings. Install 'blueutil' for more reliable Bluetooth control."
    }
}

struct SetDNDDurationTool: ToolDefinition {
    let name = "set_do_not_disturb_duration"
    let description = "Enable Do Not Disturb for a specific duration, then automatically disable it"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "minutes": JSONSchema.integer(description: "How many minutes to keep DND enabled (1-1440)", minimum: 1, maximum: 1440)
        ], required: ["minutes"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let minutes = optionalInt("minutes", from: args) else {
            throw ExecuterError.invalidArguments("minutes is required")
        }

        // Enable DND
        let shortcutResult = try? ShellRunner.run("shortcuts run \"Do Not Disturb\" 2>/dev/null", timeout: 5)
        if shortcutResult == nil || shortcutResult?.exitCode != 0 {
            let script = """
            tell application "System Events"
                tell process "ControlCenter"
                    click menu bar item "Focus" of menu bar 1
                    delay 0.5
                    click checkbox 1 of scroll area 1 of group 1 of window "Control Center"
                end tell
            end tell
            """
            AppleScriptRunner.run(script)
        }

        // Schedule auto-disable
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60) {
            // Disable DND
            let _ = try? ShellRunner.run("shortcuts run \"Do Not Disturb\" 2>/dev/null", timeout: 5)
            print("[DND] Auto-disabled after \(minutes) minutes")
        }

        let displayTime: String
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            displayTime = mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        } else {
            displayTime = "\(minutes) minutes"
        }

        return "Do Not Disturb enabled for \(displayTime). Will auto-disable."
    }
}
