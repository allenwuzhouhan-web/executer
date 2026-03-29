import Foundation
import CryptoKit
import IOKit

/// Per-device serial number for Executer installations.
/// Generated once at first launch, stored in Keychain (survives reinstalls)
/// and encrypted file (for integrity cross-checking).
enum DeviceSerial {

    private static let keychainKey = "com.executer.device-serial"
    private static let serialFileName = "device.enc"

    /// Get the device serial number. Generates one if this is the first launch.
    static var serial: String {
        // Try Keychain first (authoritative source)
        if let data = KeychainHelper.load(key: keychainKey),
           let stored = String(data: data, encoding: .utf8), !stored.isEmpty {
            return stored
        }

        // Try encrypted file (backup source)
        if let serial = loadFromEncryptedFile() {
            // Restore to Keychain
            _ = KeychainHelper.save(key: keychainKey, data: Data(serial.utf8))
            return serial
        }

        // First launch — generate new serial
        let newSerial = generateSerial()
        store(serial: newSerial)
        return newSerial
    }

    /// Check if a serial number has been generated.
    static var hasSerial: Bool {
        KeychainHelper.load(key: keychainKey) != nil
    }

    // MARK: - Generation

    private static func generateSerial() -> String {
        // Combine hardware UUID with random salt for uniqueness
        let hardwareUUID = getHardwareUUID() ?? UUID().uuidString
        let salt = UUID().uuidString
        let input = "\(hardwareUUID):\(salt):\(Date().timeIntervalSince1970)"

        // SHA256 hash → format as EX-XXXX-XXXX-XXXX-XXXX
        let hash = SHA256.hash(data: Data(input.utf8))
        let hex = hash.prefix(16).map { String(format: "%02X", $0) }.joined()

        // Format: EX-XXXX-XXXX-XXXX-XXXX (16 hex chars in 4 groups)
        let groups = stride(from: 0, to: 16, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }

        let serial = "EX-" + groups.joined(separator: "-")
        print("[DeviceSerial] Generated: \(serial)")
        return serial
    }

    /// Get the hardware UUID from IOKit (unique per machine).
    private static func getHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        if let uuidRef = IORegistryEntryCreateCFProperty(service,
                                                          "IOPlatformUUID" as CFString,
                                                          kCFAllocatorDefault, 0) {
            return uuidRef.takeRetainedValue() as? String
        }
        return nil
    }

    // MARK: - Storage

    private static func store(serial: String) {
        // Store in Keychain (primary, survives reinstall)
        let data = Data(serial.utf8)
        _ = KeychainHelper.save(key: keychainKey, data: data)

        // Store in encrypted file (secondary, for integrity verification)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(serialFileName)
        try? SecureStorage.writeEncrypted(data, to: fileURL)

        print("[DeviceSerial] Stored in Keychain + encrypted file")
    }

    private static func loadFromEncryptedFile() -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        let fileURL = dir.appendingPathComponent(serialFileName)

        guard let data = try? SecureStorage.readEncrypted(from: fileURL),
              let serial = String(data: data, encoding: .utf8) else { return nil }
        return serial
    }

    // MARK: - Integrity

    /// Verify serial consistency between Keychain and encrypted file.
    /// Returns true if both sources agree (or if first launch).
    static func verifyIntegrity() -> Bool {
        guard let keychainData = KeychainHelper.load(key: keychainKey),
              let keychainSerial = String(data: keychainData, encoding: .utf8) else {
            // No Keychain entry — could be first launch, that's OK
            return true
        }

        guard let fileSerial = loadFromEncryptedFile() else {
            // Keychain exists but file doesn't — suspicious but not fatal
            // Could happen after migration. Re-create the file.
            store(serial: keychainSerial)
            return true
        }

        // Both exist — they must match
        return keychainSerial == fileSerial
    }
}
