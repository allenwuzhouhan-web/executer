import Foundation

/// Converts VisionEngine output into ChatMessage format for the LLM.
/// Handles multimodal messages (text + base64 image) for vision-capable LLMs.
enum VisionMessageBuilder {

    /// Build a text-only screen state message.
    static func textMessage(from perception: VisionEngine.ScreenPerception) -> ChatMessage {
        let text = VisionEngine.shared.formatPerception(perception)
        return ChatMessage(
            role: "user",
            content: "[Screen State]\n\(text)"
        )
    }

    /// Build a multimodal message with text + image for vision LLMs.
    /// Returns a ChatMessage with contentBlocks for Anthropic-format multimodal content.
    static func visionMessage(from perception: VisionEngine.ScreenPerception) -> ChatMessage {
        let text = VisionEngine.shared.formatPerception(perception)

        if let base64 = perception.screenshotBase64 {
            // Multimodal: text + image
            let blocks: [[String: Any]] = [
                ["type": "text", "text": "[Screen State]\n\(text)"],
                ["type": "image", "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": base64
                ]]
            ]
            return ChatMessage(
                role: "user",
                content: "[Screen State]\n\(text)",
                contentBlocks: blocks
            )
        } else {
            return textMessage(from: perception)
        }
    }

    /// Build a diff message showing what changed since last perception.
    static func diffMessage(
        current: VisionEngine.ScreenPerception,
        previous: VisionEngine.ScreenPerception
    ) -> ChatMessage {
        var lines: [String] = ["[Screen Update]"]

        // Check app/window changes
        if current.appName != previous.appName {
            lines.append("App changed: \(previous.appName) → \(current.appName)")
        }
        if current.windowTitle != previous.windowTitle {
            lines.append("Window: \(current.windowTitle)")
        }

        // Find new interactive elements
        let prevIDs = Set(previous.elements.filter { $0.isInteractive }.map { $0.id })
        let newElements = current.elements.filter { $0.isInteractive && !prevIDs.contains($0.id) }
        let removedCount = prevIDs.subtracting(Set(current.elements.map { $0.id })).count

        if !newElements.isEmpty {
            lines.append("New elements:")
            for el in newElements.prefix(10) {
                let pos = el.clickPoint.map { "at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
                lines.append("  [\(el.id)] \(el.role) \"\(el.label)\" \(pos)")
            }
        }
        if removedCount > 0 {
            lines.append("\(removedCount) elements removed")
        }

        if lines.count == 1 {
            lines.append("No significant changes detected.")
        }

        return ChatMessage(role: "user", content: lines.joined(separator: "\n"))
    }
}
