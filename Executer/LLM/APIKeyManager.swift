import Foundation

class APIKeyManager {
    static let shared = APIKeyManager()

    private init() {}

    // MARK: - Per-Provider Key Management

    func getKey(for provider: LLMProvider) -> String? {
        let keychainKey = "\(provider.rawValue)_api_key"
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String, for provider: LLMProvider) {
        let keychainKey = "\(provider.rawValue)_api_key"
        guard let data = key.data(using: .utf8) else { return }
        _ = KeychainHelper.save(key: keychainKey, data: data)
    }

    func deleteKey(for provider: LLMProvider) {
        let keychainKey = "\(provider.rawValue)_api_key"
        KeychainHelper.delete(key: keychainKey)
    }

    func hasKey(for provider: LLMProvider) -> Bool {
        getKey(for: provider) != nil
    }

    // MARK: - Convenience (current provider)

    func getKey() -> String? {
        getKey(for: LLMServiceManager.shared.currentProvider)
    }

    var hasKey: Bool {
        hasKey(for: LLMServiceManager.shared.currentProvider)
    }
}
