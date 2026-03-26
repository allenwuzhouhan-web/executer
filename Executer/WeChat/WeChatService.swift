import Foundation

/// High-level typed API for WeChat operations.
/// Uses DIRECT Accessibility API for sending (fast, uses Executer's existing permissions).
/// Falls back to MCP subprocess for advanced operations (reading messages).
actor WeChatService {
    static let shared = WeChatService()

    private let mcpClient = WeChatMCPClient()

    var isReady: Bool {
        WeChatAccessibility.isRunning
    }

    // MARK: - Lifecycle

    func initialize() async {
        if WeChatAccessibility.isRunning {
            print("[WeChat] WeChat is running — messaging available")
        } else {
            print("[WeChat] WeChat not detected — messaging disabled")
        }
    }

    func shutdown() async {
        await mcpClient.stop()
    }

    // MARK: - Send (Direct Accessibility — fast, no subprocess)

    func sendMessage(to chatName: String, text: String) async throws {
        // Run on a background thread since AX calls use Thread.sleep
        try await Task.detached {
            try WeChatAccessibility.sendMessage(to: chatName, text: text)
        }.value

        WeChatSentLog.shared.log(recipient: chatName, text: text)
        print("[WeChat] Message sent to \(chatName)")
    }

    // MARK: - Read (MCP subprocess — only started when needed)

    func fetchMessages(chatName: String, count: Int = 20) async throws -> [WeChatMessage] {
        // Start MCP client on-demand for reading
        let result = try await mcpClient.callTool(
            name: "fetch_messages_by_chat",
            arguments: ["chat_name": chatName, "last_n": count]
        )

        if result.isError {
            let errorText = extractText(from: result.content)
            throw WeChatMCPClient.MCPError.toolError(errorText)
        }

        let text = extractText(from: result.content)
        return parseMessages(from: text)
    }

    // MARK: - Other (MCP subprocess)

    func addContact(wechatId: String, message: String? = nil) async throws {
        var args: [String: Any] = ["wechat_id": wechatId]
        if let message = message { args["message"] = message }

        let result = try await mcpClient.callTool(
            name: "add_contact_by_wechat_id",
            arguments: args
        )

        if result.isError {
            let errorText = extractText(from: result.content)
            throw WeChatMCPClient.MCPError.toolError(errorText)
        }
    }

    func postMoment(text: String, publishImmediately: Bool = false) async throws {
        let result = try await mcpClient.callTool(
            name: "publish_moment_without_media",
            arguments: ["text": text, "publish_immediately": publishImmediately]
        )

        if result.isError {
            let errorText = extractText(from: result.content)
            throw WeChatMCPClient.MCPError.toolError(errorText)
        }
    }

    // MARK: - Helpers

    private func extractText(from content: [[String: Any]]) -> String {
        content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }

    private func parseMessages(from text: String) -> [WeChatMessage] {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict -> WeChatMessage? in
            guard let sender = dict["sender"] as? String else { return nil }
            let msgText = dict["text"] as? String ?? dict["message"] as? String ?? ""
            return WeChatMessage(
                id: UUID(),
                sender: sender,
                text: msgText,
                timestamp: nil
            )
        }
    }
}

// MARK: - Models

struct WeChatMessage: Codable, Identifiable {
    let id: UUID
    let sender: String
    let text: String
    let timestamp: Date?
}
