import Foundation

/// Detects whether a user command should use the Computer Use Agent instead of the normal AgentLoop.
enum ComputerUseDetector {

    /// Check if a command requires autonomous computer control (see-think-act loop).
    static func shouldUseComputerControl(_ command: String) -> Bool {
        let lower = command.lowercased()

        // Explicit triggers
        let explicitTriggers = [
            "computer use", "control my computer", "take control",
            "use my computer", "use the computer", "control the screen",
        ]
        if explicitTriggers.contains(where: { lower.contains($0) }) { return true }

        // Task-specific triggers (things that require seeing and interacting with the screen)
        let taskTriggers = [
            "fill out the form", "fill in the form", "complete the form",
            "complete the quiz", "do the quiz", "answer the questions",
            "do the ixl", "ixl", "do my homework",
            "edit the photo", "edit the image", "edit the video",
            "crop the", "resize the image", "adjust the",
            "scroll through", "scroll down and",
            "navigate to", "go to the", "click on the",
            "click the button", "press the button",
            "type into the", "enter text in",
            "drag the", "move the slider",
            "use photoshop", "use preview", "use imovie", "use final cut",
            "use pixelmator", "use davinci",
        ]
        if taskTriggers.contains(where: { lower.contains($0) }) { return true }

        // Visual element references (implies the user wants the AI to see the screen)
        let visualRefs = [
            "the blue button", "the red button", "the green button",
            "the search bar", "the text field", "the dropdown",
            "the menu", "the toolbar", "the sidebar",
            "on screen", "on the screen", "what you see",
            "what's on screen", "look at the screen",
        ]
        if visualRefs.contains(where: { lower.contains($0) }) { return true }

        // Pattern: "do X in [app name]" where X implies interaction
        let interactionVerbs = ["edit", "modify", "change", "adjust", "crop", "trim", "cut", "paste", "draw", "paint", "type", "write", "fill", "complete", "solve", "answer"]
        let appPattern = lower.contains(" in ") || lower.contains(" on ") || lower.contains(" using ")
        if appPattern && interactionVerbs.contains(where: { lower.contains($0) }) { return true }

        return false
    }

    /// Determine the best perception mode for a command.
    static func perceptionMode(for command: String) -> ComputerUseAgent.PerceptionMode {
        let lower = command.lowercased()

        // Browser tasks: AX-only is sufficient (DOM reading is even better)
        if lower.contains("ixl") || lower.contains("browser") || lower.contains("web") {
            return .axOnly
        }

        // Photo/video editing: need screenshots for visual understanding
        let visualApps = ["photo", "image", "video", "imovie", "final cut", "davinci",
                          "photoshop", "pixelmator", "preview"]
        if visualApps.contains(where: { lower.contains($0) }) {
            return .axPlusScreenshot
        }

        // Games, canvas apps: screenshot-only
        if lower.contains("game") || lower.contains("canvas") {
            return .screenshotOnly
        }

        // Default: AX first, fallback to screenshot
        return .axFirst
    }
}
