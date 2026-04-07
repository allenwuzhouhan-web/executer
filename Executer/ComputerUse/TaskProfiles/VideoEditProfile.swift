import Foundation

/// Specialized profile for video editing in common macOS apps.
struct VideoEditProfile {

    static let systemPrompt = """
    You are editing video on macOS. Identify the current app and use app-specific shortcuts.

    APP-SPECIFIC SHORTCUTS:

    iMovie:
    - Space: Play/Pause
    - Cmd+B: Split clip at playhead
    - Cmd+Shift+B: Add freeze frame
    - Delete: Remove selected clip
    - Cmd+T: Add transition
    - Cmd+Shift+M: Mute clip
    - J/K/L: Rewind/Pause/Forward
    - Cmd+E: Export

    Final Cut Pro:
    - Space: Play/Pause
    - B: Blade tool (cut)
    - A: Select tool
    - T: Trim tool
    - Cmd+B: Blade at playhead
    - Shift+Z: Fit timeline to window
    - I/O: Set in/out points
    - Cmd+E: Export
    - V: Toggle clip enabled/disabled

    DaVinci Resolve:
    - Space: Play/Pause
    - Ctrl+B (Cmd+B): Split
    - B: Blade mode
    - A: Selection mode
    - J/K/L: Shuttle controls
    - I/O: In/Out points
    - Alt+Scroll: Zoom timeline
    - Cmd+Shift+E: Quick Export

    QuickTime Player:
    - Cmd+T: Trim mode
    - Space: Play/Pause
    - Cmd+Shift+S: Save As

    WORKFLOW:
    1. Identify the app via screen perception
    2. Navigate timeline using J/K/L shuttle or click
    3. Use keyboard shortcuts for common edits (cut, trim, split)
    4. Use mouse for precise timeline scrubbing and positioning
    5. Check result by playing back (Space)
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
        config.perceptionMode = .axPlusScreenshot  // Timelines need visual
        config.useVisionLLM = true
        config.speedMode = false
        config.toolAllowlist = toolAllowlist
        config.systemPromptOverride = systemPrompt
        return config
    }

    static func detect(command: String) -> Bool {
        let lower = command.lowercased()
        let videoKeywords = ["video", "clip", "timeline", "trim video", "cut video", "split clip",
                            "add transition", "export video", "render"]
        let videoApps = ["imovie", "final cut", "davinci", "resolve", "quicktime",
                         "premiere", "adobe premiere"]
        return videoKeywords.contains(where: { lower.contains($0) }) ||
               videoApps.contains(where: { lower.contains($0) })
    }
}
