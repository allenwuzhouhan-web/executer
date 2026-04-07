import Foundation

/// Specialized profile for photo editing in common macOS apps.
struct PhotoEditProfile {

    static let systemPrompt = """
    You are editing photos on macOS. Identify the current app and use app-specific shortcuts.

    APP-SPECIFIC SHORTCUTS:

    Preview:
    - Cmd+Shift+A: Adjust color panel
    - Cmd+K: Crop selection
    - Tools menu: Annotate, adjust, markup
    - Rotate: Cmd+R (right), Cmd+L (left)

    Photoshop:
    - Cmd+L: Levels
    - Cmd+M: Curves
    - Cmd+U: Hue/Saturation
    - Cmd+Shift+L: Auto Levels
    - Cmd+T: Free Transform
    - Filter menu: Blur, Sharpen, Noise

    Pixelmator Pro:
    - Cmd+Shift+M: ML Enhance (auto-enhance)
    - Cmd+B: Color Balance
    - E: Eraser tool
    - M: Selection tool

    Photos:
    - E: Enter edit mode
    - A: Adjust panel
    - Cmd+Shift+R: Auto Enhance
    - C: Crop
    - Return: Done editing

    GIMP:
    - Colors > Levels, Curves, Brightness-Contrast
    - Filters > Blur, Sharpen, Distort
    - Shift+Ctrl+E: Flatten Image
    - Ctrl+Shift+J: Fit Image in Window

    WORKFLOW:
    1. Identify the app via perceive_screen
    2. Use keyboard shortcuts for known operations
    3. Navigate menus for operations without shortcuts
    4. Use mouse for slider adjustments and fine positioning
    5. Verify the result by perceiving the screen after changes
    """

    static let toolAllowlist: Set<String> = [
        "perceive_screen", "perceive_screen_visual",
        "move_cursor", "click", "click_element", "scroll", "drag",
        "type_text", "press_key", "hotkey", "select_all_text", "paste_text",
        "launch_app", "switch_to_app",
        "capture_screen", "ocr_image",
    ]

    static func buildConfig() -> ComputerUseAgent.Config {
        var config = ComputerUseAgent.Config()
        config.maxIterations = 50
        config.perceptionMode = .axFirst
        config.useVisionLLM = true          // Need to see the photo
        config.speedMode = false            // Precision over speed
        config.toolAllowlist = toolAllowlist
        config.systemPromptOverride = systemPrompt
        return config
    }

    static func detect(command: String) -> Bool {
        let lower = command.lowercased()
        let photoKeywords = ["photo", "image", "picture", "crop", "resize image", "adjust color",
                            "brightness", "contrast", "filter", "retouch", "red eye"]
        let photoApps = ["preview", "photoshop", "pixelmator", "photos", "gimp", "affinity photo", "lightroom"]
        return photoKeywords.contains(where: { lower.contains($0) }) ||
               photoApps.contains(where: { lower.contains($0) })
    }
}
