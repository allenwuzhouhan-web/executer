import SwiftUI

// MARK: - Platform Definition

enum MessagingPlatform: String, CaseIterable, Codable {
    case wechat, imessage, whatsapp

    var displayName: String {
        switch self {
        case .wechat: return "WeChat"
        case .imessage: return "iMessage"
        case .whatsapp: return "WhatsApp"
        }
    }

    var icon: String {
        switch self {
        case .wechat: return "bubble.left.fill"
        case .imessage: return "message.fill"
        case .whatsapp: return "phone.bubble.fill"
        }
    }

    var color: Color {
        switch self {
        case .wechat: return Color(red: 0.027, green: 0.757, blue: 0.373)
        case .imessage: return .blue
        case .whatsapp: return Color(red: 0.145, green: 0.827, blue: 0.400)
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .wechat: return "com.tencent.xinWeChat"
        case .imessage: return "com.apple.MobileSMS"
        case .whatsapp: return "net.whatsapp.WhatsApp"
        }
    }
}

// MARK: - Service Protocol

protocol MessagingService {
    var platform: MessagingPlatform { get }
    var isAvailable: Bool { get }
    func sendMessage(to contact: String, text: String) async throws
}

// MARK: - Error

enum MessagingError: LocalizedError {
    case platformNotAvailable(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .platformNotAvailable(let name): return "\(name) is not available."
        case .sendFailed(let msg): return "Send failed: \(msg)"
        }
    }
}

// MARK: - Manager

class MessagingManager {
    static let shared = MessagingManager()

    var preferredPlatform: MessagingPlatform {
        get {
            if let raw = UserDefaults.standard.string(forKey: "messaging_platform"),
               let p = MessagingPlatform(rawValue: raw) { return p }
            return .wechat
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "messaging_platform") }
    }

    private let services: [MessagingPlatform: MessagingService] = [
        .wechat: WeChatServiceAdapter(),
        .imessage: IMessageService(),
        .whatsapp: WhatsAppService(),
    ]

    func service(for platform: MessagingPlatform) -> MessagingService? {
        services[platform]
    }

    func sendMessage(to contact: String, text: String, platform: MessagingPlatform? = nil) async throws {
        let target = platform ?? preferredPlatform
        guard let svc = services[target] else {
            throw MessagingError.platformNotAvailable(target.displayName)
        }
        try await svc.sendMessage(to: contact, text: text)
        WeChatSentLog.shared.log(recipient: contact, text: text, platform: target.rawValue)
    }

    private init() {}
}

// MARK: - WeChat Adapter

/// Wraps existing WeChatService to conform to MessagingService.
class WeChatServiceAdapter: MessagingService {
    let platform = MessagingPlatform.wechat
    var isAvailable: Bool { WeChatAccessibility.isRunning }

    func sendMessage(to contact: String, text: String) async throws {
        try await WeChatService.shared.sendMessage(to: contact, text: text)
    }
}
