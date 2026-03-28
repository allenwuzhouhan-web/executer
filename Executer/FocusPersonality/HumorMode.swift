import Foundation

/// Humor mode transforms boring status messages into chaotic, funny alternatives.
/// Your Mac becomes your unhinged best friend.
class HumorMode {
    static let shared = HumorMode()
    private init() {}

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "humor_mode_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "humor_mode_enabled") }
    }

    // MARK: - Public API (delegates to LanguageManager for localized messages)

    func funnyThinking() -> String {
        LanguageManager.shared.humorMessages.thinkingMessages.randomElement()!
    }

    func funnyToolStatus(toolName: String, step: Int, total: Int) -> String {
        let msgs = LanguageManager.shared.humorMessages
        let messages = msgs.toolMessages[toolName] ?? msgs.genericToolMessages
        let msg = messages.randomElement()!
        return "\(msg) (\(step)/\(total))"
    }

    func funnyResult(_ original: String) -> String {
        let prefix = LanguageManager.shared.humorMessages.successPrefixes.randomElement()!
        if original.count < 60 {
            return "\(prefix)\(original)"
        }
        return original
    }

    func funnyHealthMessage(isHealthy: Bool, diskUsedPercent: Int) -> String {
        let msgs = LanguageManager.shared.humorMessages
        if !isHealthy && diskUsedPercent >= 85 {
            return msgs.diskWarningMessages.randomElement()!
        }
        return msgs.healthyMessages.randomElement()!
    }
}
