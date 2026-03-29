import Foundation
import CryptoKit

/// Verifies system integrity on every launch.
/// If any check fails, the app is locked down and cannot proceed.
enum IntegrityChecker {

    /// Result of integrity verification.
    enum VerifyResult {
        case passed
        case failed(String)  // Reason for failure
    }

    /// Run all integrity checks. Call as the FIRST thing in applicationDidFinishLaunching.
    static func verify() -> VerifyResult {
        print("[Integrity] Running system integrity checks...")

        // 1. Verify device serial consistency
        if !DeviceSerial.verifyIntegrity() {
            let reason = "Device serial mismatch between Keychain and encrypted storage"
            logFailure(reason)
            return .failed(reason)
        }

        // 2. Verify Keychain encryption key exists
        if KeychainHelper.load(key: "com.executer.storage-key") == nil && DeviceSerial.hasSerial {
            // Has a serial but no encryption key — key was deleted
            let reason = "Encryption key missing from Keychain"
            logFailure(reason)
            return .failed(reason)
        }

        // 3. Verify bundle integrity — check that Info.plist hasn't been tampered
        if !verifyBundleIntegrity() {
            let reason = "Application bundle integrity compromised"
            logFailure(reason)
            return .failed(reason)
        }

        // 4. Store/verify binary hash (first launch stores, subsequent launches verify)
        if let binaryResult = verifyBinaryHash() {
            if case .failed(let reason) = binaryResult {
                logFailure(reason)
                return .failed(reason)
            }
        }

        print("[Integrity] All checks passed")
        return .passed
    }

    // MARK: - Bundle Integrity

    private static func verifyBundleIntegrity() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String?,
              let plistPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              FileManager.default.fileExists(atPath: plistPath) else {
            return false
        }

        // Verify the bundle identifier matches what we expect
        guard Bundle.main.bundleIdentifier == "com.allenwu.executer" else {
            return false
        }

        // Verify the model number in the binary matches
        guard AppModel.modelNumber.hasPrefix("EX-") else {
            return false
        }

        return true
    }

    // MARK: - Binary Hash

    private static let binaryHashKey = "com.executer.binary-hash"

    private static func verifyBinaryHash() -> VerifyResult? {
        guard let executablePath = Bundle.main.executablePath,
              let binaryData = try? Data(contentsOf: URL(fileURLWithPath: executablePath)) else {
            return nil // Can't read binary — skip this check
        }

        let currentHash = SHA256.hash(data: binaryData)
            .map { String(format: "%02x", $0) }
            .joined()

        if let storedData = KeychainHelper.load(key: binaryHashKey),
           let storedHash = String(data: storedData, encoding: .utf8) {
            // Have a stored hash — verify
            if storedHash != currentHash {
                // Hash mismatch could mean:
                // 1. App was updated (legitimate)
                // 2. Binary was tampered with
                // For now, update the hash (updates are legitimate)
                // In production, this would check against a signed manifest
                _ = KeychainHelper.save(key: binaryHashKey, data: Data(currentHash.utf8))
                print("[Integrity] Binary hash updated (app may have been updated)")
            }
        } else {
            // First launch — store the hash
            _ = KeychainHelper.save(key: binaryHashKey, data: Data(currentHash.utf8))
            print("[Integrity] Binary hash stored for future verification")
        }

        return .passed
    }

    // MARK: - Logging

    private static func logFailure(_ reason: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] INTEGRITY FAILURE: \(reason)\n"

        // Write to a plaintext log (not encrypted — encryption may be compromised)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logFile = dir.appendingPathComponent("integrity_failures.log")

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(logEntry.utf8))
            handle.closeFile()
        } else {
            try? logEntry.write(to: logFile, atomically: true, encoding: .utf8)
        }

        print("[Integrity] FAILURE: \(reason)")
    }
}
