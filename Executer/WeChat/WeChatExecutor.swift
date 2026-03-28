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
        MessageRouter.shared.addContact(chatName)
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
    let description = "Send a message to a contact via the user's preferred messaging platform (WeChat, iMessage, or WhatsApp)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The recipient's name"),
            "message": JSONSchema.string(description: "The message text to send"),
        ], required: ["contact", "message"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let message = try requiredString("message", from: args)

        try await MessagingManager.shared.sendMessage(to: contact, text: message)
        MessageRouter.shared.addContact(contact)
        let platform = MessagingManager.shared.preferredPlatform
        return "Message sent to \(contact) via \(platform.displayName)."
    }
}

struct SendIMessageTool: ToolDefinition {
    let name = "send_imessage"
    let description = "Send a message via iMessage (Apple Messages app)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The recipient's name or phone number"),
            "message": JSONSchema.string(description: "The message text to send"),
        ], required: ["contact", "message"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let message = try requiredString("message", from: args)

        try await MessagingManager.shared.sendMessage(to: contact, text: message, platform: .imessage)
        MessageRouter.shared.addContact(contact)
        return "Message sent to \(contact) via iMessage."
    }
}

struct SendWhatsAppMessageTool: ToolDefinition {
    let name = "send_whatsapp_message"
    let description = "Send a message via WhatsApp."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The recipient's name"),
            "message": JSONSchema.string(description: "The message text to send"),
        ], required: ["contact", "message"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let message = try requiredString("message", from: args)

        try await MessagingManager.shared.sendMessage(to: contact, text: message, platform: .whatsapp)
        MessageRouter.shared.addContact(contact)
        return "Message sent to \(contact) via WhatsApp."
    }
}

struct ReadMessagesTool: ToolDefinition {
    let name = "read_messages"
    let description = "Read recent messages from a WeChat contact or group chat"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "contact": JSONSchema.string(description: "The contact name to read messages from"),
            "count": JSONSchema.integer(description: "Number of messages (default 10)", minimum: 1, maximum: 50),
        ], required: ["contact"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let contact = try requiredString("contact", from: args)
        let count = optionalInt("count", from: args) ?? 10

        let messages = try await WeChatService.shared.fetchMessages(chatName: contact, count: count)
        if messages.isEmpty {
            return "No recent messages found from \(contact) on WeChat."
        }
        let formatted = messages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        return "Recent WeChat messages from \(contact):\n\(formatted)"
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
