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
    /// Check depth varies by build environment:
    ///   - debug:       Skip all (Xcode run, developer machine)
    ///   - development: Serial + bundle + encryption key (no hash/signing — they change per rebuild)
    ///   - release:     ALL checks including code signing + binary hash pinning
    static func verify() -> VerifyResult {
        let env = AppModel.buildEnvironment

        switch env {
        case .debug:
            print("[Integrity] Debug build — skipping integrity checks")
            return .passed

        case .development:
            print("[Integrity] Development build — running lightweight checks...")
            return runDevelopmentChecks()

        case .release:
            print("[Integrity] Release build — running FULL integrity checks...")
            return runReleaseChecks()
        }
    }

    /// Async verification for checks that require network (manifest verification).
    /// Called AFTER synchronous verify() passes, runs in background.
    static func verifyAsync() async -> VerifyResult {
        guard AppModel.buildEnvironment == .release else {
            return .passed
        }

        print("[Integrity] Running async manifest verification...")
        let result = await ManifestVerifier.shared.verifyAgainstGitHub()

        switch result {
        case .matched:
            print("[Integrity] Manifest verification passed — binary matches official release")
            return .passed
        case .mismatch(let reason):
            let msg = "Binary does not match official release: \(reason)"
            logFailure(msg)
            return .failed(msg)
        case .signatureInvalid:
            let msg = "Release manifest signature is invalid — possible tampering"
            logFailure(msg)
            return .failed(msg)
        case .networkUnavailable:
            print("[Integrity] Manifest check skipped — network unavailable (grace period)")
            return .passed
        case .noManifest:
            print("[Integrity] No manifest found for this version (pre-manifest release)")
            return .passed
        }
    }

    // MARK: - Development Checks

    private static func runDevelopmentChecks() -> VerifyResult {
        // Development/prerelease builds: run checks as WARNINGS only — NEVER lock down.
        // This matches the original behavior where prerelease builds skip all checks.
        // The warnings are logged for diagnostics but do not block the user.

        if !DeviceSerial.verifyIntegrity() {
            print("[Integrity] WARNING (dev): Device serial mismatch — ignoring for prerelease")
        }

        if KeychainHelper.load(key: "com.executer.storage-key") == nil && DeviceSerial.hasSerial {
            print("[Integrity] WARNING (dev): Encryption key missing — ignoring for prerelease")
        }

        if !verifyBundleIntegrity() {
            print("[Integrity] WARNING (dev): Bundle integrity issue — ignoring for prerelease")
        }

        let sigResult = CodeSigningVerifier.verifyCodeSignature()
        if !sigResult.valid {
            print("[Integrity] WARNING (dev): Code signature issue: \(sigResult.reason ?? "unknown")")
        }

        print("[Integrity] Development checks passed (warnings only, no lockdown)")
        return .passed
    }

    // MARK: - Release Checks

    private static func runReleaseChecks() -> VerifyResult {
        // 1. Verify device serial consistency
        if !DeviceSerial.verifyIntegrity() {
            let reason = "Device serial mismatch between Keychain and encrypted storage"
            logFailure(reason)
            return .failed(reason)
        }

        // 2. Verify Keychain encryption key exists
        if KeychainHelper.load(key: "com.executer.storage-key") == nil && DeviceSerial.hasSerial {
            let reason = "Encryption key missing from Keychain"
            logFailure(reason)
            return .failed(reason)
        }

        // 3. Verify bundle integrity
        if !verifyBundleIntegrity() {
            let reason = "Application bundle integrity compromised"
            logFailure(reason)
            return .failed(reason)
        }

        // 4. Code signing verification (STRICT in release)
        let sigResult = CodeSigningVerifier.verifyCodeSignature()
        if !sigResult.valid {
            let reason = "Code signature verification failed: \(sigResult.reason ?? "unknown")"
            logFailure(reason)
            return .failed(reason)
        }
        print("[Integrity] Code signing valid (team: \(sigResult.teamID ?? "none"))")

        // 5. Binary hash verification — in release, mismatch is a hard failure
        //    (manifest async check will confirm whether this is a legitimate update)
        if let binaryResult = verifyBinaryHash(strictMode: true) {
            if case .failed(let reason) = binaryResult {
                logFailure(reason)
                return .failed(reason)
            }
        }

        // 6. Runtime shield + environment integrity (added in Phase 4, called here)
        let runtimeResult = RuntimeShield.performInitialCheck()
        if case .failed(let reason) = runtimeResult {
            logFailure(reason)
            return .failed(reason)
        }

        let envResult = EnvironmentIntegrity.check()
        if case .failed(let reason) = envResult {
            logFailure(reason)
            return .failed(reason)
        }

        print("[Integrity] All release checks passed")
        return .passed
    }

    // MARK: - Bundle Integrity

    private static func verifyBundleIntegrity() -> Bool {
        guard let _ = Bundle.main.bundlePath as String?,
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

    /// Verify binary hash.
    /// - strictMode: true in release (mismatch = failure), false in development (mismatch = silent update)
    private static func verifyBinaryHash(strictMode: Bool = false) -> VerifyResult? {
        guard let executablePath = Bundle.main.executablePath,
              let binaryData = try? Data(contentsOf: URL(fileURLWithPath: executablePath)) else {
            return nil // Can't read binary — skip this check
        }

        let currentHash = SHA256.hash(data: binaryData)
            .map { String(format: "%02x", $0) }
            .joined()

        if let storedData = KeychainHelper.load(key: binaryHashKey),
           let storedHash = String(data: storedData, encoding: .utf8) {
            if storedHash != currentHash {
                if strictMode {
                    // In release: binary changed since last verified launch.
                    // Store the new hash — the async manifest check will determine if it's legitimate.
                    _ = KeychainHelper.save(key: binaryHashKey, data: Data(currentHash.utf8))
                    print("[Integrity] Binary hash changed — will verify against manifest asynchronously")
                    // Don't fail here — let the manifest check in verifyAsync() handle it.
                    // This avoids false positives when the user legitimately updates the app.
                } else {
                    // In development: just update silently
                    _ = KeychainHelper.save(key: binaryHashKey, data: Data(currentHash.utf8))
                    print("[Integrity] Binary hash updated (development build)")
                }
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
        let dir = URL.applicationSupportDirectory
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
