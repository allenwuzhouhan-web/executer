import Foundation
import CryptoKit
import Security

/// Verifies the macOS environment's security posture — SIP, Gatekeeper, Hardened Runtime.
/// Also monitors critical file hashes at runtime to detect live tampering.
enum EnvironmentIntegrity {

    /// Environment check results.
    struct Status {
        var sipEnabled: Bool?
        var gatekeeperEnabled: Bool?
        var hardenedRuntimeValid: Bool?
        var warnings: [String] = []
    }

    /// Shared status — updated on each check.
    private(set) static var lastStatus = Status()

    /// Perform environment integrity check. Returns .passed or .failed for critical issues.
    /// Warnings (SIP disabled, Gatekeeper disabled) are logged but do NOT cause lockdown.
    static func check() -> IntegrityChecker.VerifyResult {
        let env = AppModel.buildEnvironment

        guard env != .debug else {
            print("[Environment] Debug build — skipping environment checks")
            return .passed
        }

        var status = Status()

        // 1. SIP status
        status.sipEnabled = checkSIPEnabled()
        if status.sipEnabled == false {
            status.warnings.append("System Integrity Protection (SIP) is disabled")
            print("[Environment] WARNING: SIP is disabled")
        }

        // 2. Gatekeeper status
        status.gatekeeperEnabled = checkGatekeeperEnabled()
        if status.gatekeeperEnabled == false {
            status.warnings.append("Gatekeeper assessments are disabled")
            print("[Environment] WARNING: Gatekeeper is disabled")
        }

        // 3. Hardened Runtime self-check
        status.hardenedRuntimeValid = checkHardenedRuntime()
        if status.hardenedRuntimeValid == false && env == .release {
            let reason = "Hardened Runtime validation failed"
            print("[Environment] FAILURE: \(reason)")
            lastStatus = status
            return .failed(reason)
        }

        // 4. Store initial file hashes for live monitoring
        storeInitialHashes()

        lastStatus = status

        if !status.warnings.isEmpty {
            print("[Environment] Checks passed with \(status.warnings.count) warning(s)")
        } else {
            print("[Environment] All environment checks passed")
        }

        return .passed
    }

    // MARK: - SIP Check

    private static func checkSIPEnabled() -> Bool? {
        // csrutil status returns "System Integrity Protection status: enabled."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress stderr

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("enabled") {
                return true
            } else if output.contains("disabled") {
                return false
            }
            return nil // Unknown output format
        } catch {
            print("[Environment] Could not check SIP status: \(error)")
            return nil
        }
    }

    // MARK: - Gatekeeper Check

    private static func checkGatekeeperEnabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--status"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // spctl writes to stderr

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("assessments enabled") {
                return true
            } else if output.contains("assessments disabled") {
                return false
            }
            return nil
        } catch {
            print("[Environment] Could not check Gatekeeper status: \(error)")
            return nil
        }
    }

    // MARK: - Hardened Runtime Self-Check

    private static func checkHardenedRuntime() -> Bool {
        let result = CodeSigningVerifier.verifyCodeSignature()
        return result.valid
    }

    // MARK: - File Integrity Monitoring

    private static var initialHashes: [String: String] = [:]
    private static var monitorTimer: DispatchSourceTimer?

    /// Store SHA256 hashes of critical files for live monitoring.
    private static func storeInitialHashes() {
        let criticalPaths = [
            Bundle.main.executablePath,
            Bundle.main.path(forResource: "Info", ofType: "plist"),
        ].compactMap { $0 }

        for path in criticalPaths {
            if let hash = hashFile(at: path) {
                initialHashes[path] = hash
            }
        }
    }

    /// Start periodic file integrity monitoring (every 60s).
    static func startFileMonitoring() {
        guard AppModel.buildEnvironment == .release else { return }
        guard monitorTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            for (path, expectedHash) in initialHashes {
                if let currentHash = hashFile(at: path), currentHash != expectedHash {
                    print("[Environment] TAMPER DETECTED: \(path) hash changed")
                    DispatchQueue.main.async {
                        let lockdown = LockdownWindow()
                        lockdown.show(reason: "Critical file modified while app is running: \((path as NSString).lastPathComponent)")
                    }
                    return
                }
            }
        }
        timer.resume()
        monitorTimer = timer
        print("[Environment] File integrity monitoring started (60s interval)")
    }

    static func stopFileMonitoring() {
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    private static func hashFile(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Dashboard Summary

    static func statusSummary() -> String {
        let s = lastStatus
        var lines: [String] = []
        lines.append("SIP: \(s.sipEnabled == true ? "Enabled" : s.sipEnabled == false ? "DISABLED" : "Unknown")")
        lines.append("Gatekeeper: \(s.gatekeeperEnabled == true ? "Enabled" : s.gatekeeperEnabled == false ? "DISABLED" : "Unknown")")
        lines.append("Hardened Runtime: \(s.hardenedRuntimeValid == true ? "Valid" : s.hardenedRuntimeValid == false ? "INVALID" : "Unknown")")
        if !s.warnings.isEmpty {
            lines.append("Warnings: \(s.warnings.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}
