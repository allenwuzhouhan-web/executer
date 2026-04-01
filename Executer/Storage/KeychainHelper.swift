import Foundation
import Security
import LocalAuthentication

enum KeychainHelper {

    // MARK: - Standard Save (with device-bound access control)

    static func save(key: String, data: Data, service: String = "com.executer.app") -> Bool {
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // Device-bound: not included in backups, not migratable to other devices
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Biometric-Protected Save

    /// Save with biometric (Touch ID) protection. The item requires biometric auth to read.
    /// Falls back to standard save if biometric hardware is unavailable.
    static func saveBiometric(key: String, data: Data, service: String = "com.executer.app") -> Bool {
        // Only use biometric protection in release builds with hardware support
        guard AppModel.buildEnvironment == .release else {
            return save(key: key, data: data, service: service)
        }

        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            // No biometric hardware — fall back to standard save
            return save(key: key, data: data, service: service)
        }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Create access control with biometric requirement
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            return save(key: key, data: data, service: service)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        } else {
            // Biometric save failed — fall back to standard
            print("[Keychain] Biometric save failed (OSStatus: \(status)), falling back to standard")
            return save(key: key, data: data, service: service)
        }
    }

    // MARK: - Load

    static func load(key: String, service: String = "com.executer.app") -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Delete

    static func delete(key: String, service: String = "com.executer.app") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
