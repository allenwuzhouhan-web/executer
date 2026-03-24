import Foundation
import UserNotifications
import AVFoundation

struct ShowNotificationTool: ToolDefinition {
    let name = "show_notification"
    let description = "Show a system notification"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The notification title"),
            "body": JSONSchema.string(description: "The notification body text"),
            "sound": JSONSchema.boolean(description: "Whether to play a sound (default true)")
        ], required: ["title", "body"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let body = try requiredString("body", from: args)
        let sound = optionalBool("sound", from: args) ?? true

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        try await UNUserNotificationCenter.current().add(request)
        return "Notification sent: \(title)"
    }
}

struct SpeakTextTool: ToolDefinition {
    let name = "speak_text"
    let description = "Speak text aloud using text-to-speech"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to speak aloud"),
            "voice": JSONSchema.string(description: "Optional voice name (e.g., 'Samantha', 'Alex', 'Daniel')")
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)
        let voice = optionalString("voice", from: args)

        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        if let voice = voice {
            _ = try ShellRunner.run("say -v \"\(voice)\" \"\(escaped)\"")
        } else {
            _ = try ShellRunner.run("say \"\(escaped)\"")
        }
        return "Spoke: \"\(text)\""
    }
}
