import Foundation
import CryptoKit

/// Encryption and integrity verification for sensitive data at rest.
enum SecureStorage {
    /// Cached key — avoids 5-10ms Keychain round-trip on every crypto operation.
    private static var cachedKey: SymmetricKey?

    /// Derive (or create) an AES-256 encryption key stored in Keychain.
    private static func getOrCreateKey() -> SymmetricKey {
        if let cached = cachedKey { return cached }
        let keyLabel = "com.executer.storage-key"
        if let existing = KeychainHelper.load(key: keyLabel) {
            let key = SymmetricKey(data: existing)
            cachedKey = key
            return key
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        _ = KeychainHelper.save(key: keyLabel, data: keyData)
        cachedKey = newKey
        return newKey
    }

    /// Write AES-256-GCM encrypted data to a URL. Sets file permissions to 600.
    static func writeEncrypted(_ data: Data, to url: URL) throws {
        let key = getOrCreateKey()
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "SecureStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read and decrypt AES-256-GCM encrypted data from a URL.
    static func readEncrypted(from url: URL) throws -> Data {
        let key = getOrCreateKey()
        let combined = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    /// Compute HMAC-SHA256 for integrity verification.
    static func hmac(for data: Data) -> Data {
        let key = getOrCreateKey()
        let auth = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(auth)
    }

    /// Verify HMAC-SHA256 integrity.
    static func verifyHMAC(_ mac: Data, for data: Data) -> Bool {
        let key = getOrCreateKey()
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
    }
}

/// Envelope for data + HMAC integrity check.
struct IntegrityEnvelope: Codable {
    let data: Data
    let hmac: Data
}
