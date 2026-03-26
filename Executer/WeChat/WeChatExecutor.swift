import Foundation

// MARK: - WeChat Tools

struct SendWeChatMessageTool: ToolDefinition {
    let name = "send_wechat_message"
    let description = "Send a message to a WeChat contact or group chat. Requires user confirmation before sending."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "chat_name": JSONSchema.string(description: "The WeChat contact name or group chat name (e.g. '妈妈', '文件传输助手')"),
            "message": JSONSchema.string(description: "The message text to send"),
        ], required: ["chat_name", "message"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let chatName = try requiredString("chat_name", from: args)
        let message = try requiredString("message", from: args)

        try await WeChatService.shared.sendMessage(to: chatName, text: message)
        return "Message sent to \(chatName) via WeChat."
    }
}

struct FetchWeChatMessagesTool: ToolDefinition {
    let name = "fetch_wechat_messages"
    let description = "Read recent messages from a WeChat contact or group chat"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "chat_name": JSONSchema.string(description: "The contact or group name to read messages from"),
            "count": JSONSchema.integer(description: "Number of recent messages to fetch (default 20)", minimum: 1, maximum: 100),
        ], required: ["chat_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let chatName = try requiredString("chat_name", from: args)
        let count = optionalInt("count", from: args) ?? 20

        let messages = try await WeChatService.shared.fetchMessages(chatName: chatName, count: count)

        if messages.isEmpty {
            return "No messages found in chat with \(chatName)."
        }

        let formatted = messages.map { msg in
            "\(msg.sender): \(msg.text)"
        }.joined(separator: "\n")

        return "Recent messages from \(chatName) (\(messages.count)):\n\(formatted)"
    }
}

struct SendMessageTool: ToolDefinition {
    let name = "send_message"
    let description = "Send a message to a contact via the best platform (iMessage or WeChat). Automatically routes based on contact preferences. If unsure, specify the platform."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The recipient's name"),
            "message": JSONSchema.string(description: "The message text to send"),
            "platform": JSONSchema.enumString(
                description: "Which platform to use. 'auto' will pick based on contact preferences and language.",
                values: ["auto", "wechat", "imessage"]
            ),
        ], required: ["contact", "message"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let message = try requiredString("message", from: args)
        let platformStr = optionalString("platform", from: args) ?? "auto"

        let platform: MessageRouter.MessagePlatform

        if platformStr == "auto" {
            // Let the router decide
            guard let routed = MessageRouter.shared.route(contact: contact, messageText: message) else {
                return "I'm not sure whether to send this via iMessage or WeChat. Please specify: send_message with platform 'wechat' or 'imessage'."
            }
            platform = routed
        } else if platformStr == "wechat" {
            platform = .wechat
        } else {
            platform = .imessage
        }

        switch platform {
        case .wechat:
            try await WeChatService.shared.sendMessage(to: contact, text: message)
            // Remember this route for future
            MessageRouter.shared.setRoute(contact: contact, platform: .wechat)
            return "Message sent to \(contact) via WeChat."

        case .imessage:
            // Use existing AppleScript approach for iMessage
            let escaped = AppleScriptRunner.escape(message)
            let contactEscaped = AppleScriptRunner.escape(contact)
            let script = """
            tell application "Messages"
                set targetBuddy to buddy "\(contactEscaped)" of service "iMessage"
                send "\(escaped)" to targetBuddy
            end tell
            """
            try AppleScriptRunner.runThrowing(script)
            WeChatSentLog.shared.log(recipient: contact, text: message, platform: "imessage")
            MessageRouter.shared.setRoute(contact: contact, platform: .imessage)
            return "Message sent to \(contact) via iMessage."
        }
    }
}

struct ReadMessagesTool: ToolDefinition {
    let name = "read_messages"
    let description = "Read recent messages from a contact. Checks WeChat if the contact is mapped there, otherwise describes how to check iMessage."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The contact name to read messages from"),
            "count": JSONSchema.integer(description: "Number of messages (default 10)", minimum: 1, maximum: 50),
            "platform": JSONSchema.enumString(description: "Platform to check", values: ["auto", "wechat"]),
        ], required: ["contact"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let count = optionalInt("count", from: args) ?? 10
        let platformStr = optionalString("platform", from: args) ?? "auto"

        let useWeChat = platformStr == "wechat" ||
            (platformStr == "auto" && MessageRouter.shared.route(contact: contact, messageText: "") == .wechat)

        if useWeChat {
            let messages = try await WeChatService.shared.fetchMessages(chatName: contact, count: count)
            if messages.isEmpty {
                return "No recent messages found from \(contact) on WeChat."
            }
            let formatted = messages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
            return "Recent WeChat messages from \(contact):\n\(formatted)"
        } else {
            return "iMessage reading is not directly supported. Please open Messages.app to view messages from \(contact)."
        }
    }
}

struct SetContactPlatformTool: ToolDefinition {
    let name = "set_contact_platform"
    let description = "Set a contact's preferred messaging platform (iMessage or WeChat). Used when user says things like 'mom is on WeChat'."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The contact name"),
            "platform": JSONSchema.enumString(description: "The platform", values: ["wechat", "imessage"]),
        ], required: ["contact", "platform"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let platformStr = try requiredString("platform", from: args)

        let platform: MessageRouter.MessagePlatform = platformStr == "wechat" ? .wechat : .imessage
        MessageRouter.shared.setRoute(contact: contact, platform: platform)
        return "Got it — \(contact) is on \(platform.rawValue). Future messages will go there by default."
    }
}

struct WeChatSentHistoryTool: ToolDefinition {
    let name = "wechat_sent_history"
    let description = "Show messages sent via WeChat today or recently"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "days": JSONSchema.integer(description: "Number of days to look back (default 1 = today)", minimum: 1, maximum: 30),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let days = optionalInt("days", from: args) ?? 1

        let entries: [WeChatSentLog.Entry]
        if days == 1 {
            entries = WeChatSentLog.shared.todayEntries()
        } else {
            entries = WeChatSentLog.shared.recentEntries(days: days)
        }

        return WeChatSentLog.shared.formatEntries(entries)
    }
}
