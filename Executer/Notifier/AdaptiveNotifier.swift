import Foundation

/// Smart communication layer — chooses channel (notification/email/voice/queue) based on urgency, user state, and time.
actor AdaptiveNotifier {
    static let shared = AdaptiveNotifier()

    /// Messages queued for batch delivery (morning console).
    private var batchedMessages: [NotifierMessage] = []

    /// Messages queued for next user interaction.
    private var pendingMessages: [NotifierMessage] = []

    struct NotifierMessage: Sendable {
        let title: String
        let body: String
        let urgency: Double
        let source: String
        let timestamp: Date
    }

    // MARK: - Deliver

    /// Route a message to the appropriate channel based on urgency and user state.
    func deliver(title: String, body: String, urgency: Double, source: String) async {
        let hour = Calendar.current.component(.hour, from: Date())
        let isDND = FocusStateService.shared.currentFocus != .none
        let isDeepWork = await isUserInDeepWork()

        let channel = NotificationPolicy.route(
            urgency: urgency,
            currentHour: hour,
            isDND: isDND,
            isDeepWork: isDeepWork
        )

        let message = NotifierMessage(
            title: title,
            body: body,
            urgency: urgency,
            source: source,
            timestamp: Date()
        )

        switch channel {
        case .immediate:
            await deliverImmediate(message)
        case .nextInteraction:
            pendingMessages.append(message)
        case .batch:
            batchedMessages.append(message)
        case .suppress:
            break
        }

        print("[AdaptiveNotifier] \(title) → \(channel.rawValue) (urgency: \(String(format: "%.1f", urgency)))")
    }

    // MARK: - Channel Implementations

    private func deliverImmediate(_ message: NotifierMessage) async {
        do {
            _ = try await ToolRegistry.shared.execute(
                toolName: "show_notification",
                arguments: "{\"title\": \"\(message.title.replacingOccurrences(of: "\"", with: "'"))\", \"body\": \"\(String(message.body.prefix(200)).replacingOccurrences(of: "\"", with: "'"))\"}"
            )
        } catch {
            print("[AdaptiveNotifier] Notification failed: \(error)")
        }
    }

    // MARK: - Queries

    /// Get messages pending for next user interaction.
    func getPendingMessages() -> [NotifierMessage] { pendingMessages }

    /// Consume pending messages (mark as delivered).
    func consumePendingMessages() -> [NotifierMessage] {
        let messages = pendingMessages
        pendingMessages = []
        return messages
    }

    /// Get batched messages for morning console.
    func getBatchedMessages() -> [NotifierMessage] { batchedMessages }

    /// Consume batched messages (mark as delivered).
    func consumeBatchedMessages() -> [NotifierMessage] {
        let messages = batchedMessages
        batchedMessages = []
        return messages
    }

    // MARK: - User State

    private func isUserInDeepWork() async -> Bool {
        let state = await WorkStateEngine.shared.snapshot()
        return state.activityType == .coding || state.activityType == .writing
    }
}
