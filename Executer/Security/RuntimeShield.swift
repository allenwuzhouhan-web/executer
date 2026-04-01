import Foundation
import Darwin
import CryptoKit

/// Runtime tamper detection — checks for DYLD injection, debugger attachment, and unauthorized libraries.
/// Behavior varies by build environment:
///   - debug:       All checks skipped
///   - development: DYLD + library checks as warnings only
///   - release:     All checks enforced, periodic re-checks every 30s
enum RuntimeShield {

    /// Result of a runtime check.
    enum CheckResult {
        case passed
        case failed(String)
        case warning(String)
    }

    // MARK: - Initial Check (called from IntegrityChecker)

    /// Perform all runtime checks once. Called during app launch.
    static func performInitialCheck() -> IntegrityChecker.VerifyResult {
        let env = AppModel.buildEnvironment

        guard env != .debug else {
            print("[RuntimeShield] Debug build — skipping runtime checks")
            return .passed
        }

        // 1. DYLD injection detection
        let dyldResult = checkDYLDInjection()
        if case .failed(let reason) = dyldResult, env == .release {
            return .failed(reason)
        } else if case .failed(let reason) = dyldResult {
            print("[RuntimeShield] WARNING (dev): \(reason)")
        }

        // 2. Debugger detection (release only — devs need debuggers)
        if env == .release {
            let debugResult = checkDebuggerAttached()
            if case .failed(let reason) = debugResult {
                return .failed(reason)
            }
        }

        // 3. Library validation
        let libResult = checkLoadedLibraries()
        if case .failed(let reason) = libResult, env == .release {
            return .failed(reason)
        } else if case .failed(let reason) = libResult {
            print("[RuntimeShield] WARNING (dev): \(reason)")
        }

        print("[RuntimeShield] All runtime checks passed")
        return .passed
    }

    // MARK: - Periodic Re-checks (release only)

    private static var periodicTimer: DispatchSourceTimer?

    /// Start periodic re-checks every 30 seconds. Release builds only.
    /// Detects post-launch debugger attachment or late DYLD injection.
    static func startPeriodicChecks() {
        guard AppModel.buildEnvironment == .release else { return }
        guard periodicTimer == nil else { return } // Already running

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler {
            let results = [
                checkDYLDInjection(),
                checkDebuggerAttached(),
                checkLoadedLibraries()
            ]

            for result in results {
                if case .failed(let reason) = result {
                    print("[RuntimeShield] PERIODIC CHECK FAILED: \(reason)")
                    DispatchQueue.main.async {
                        let lockdown = LockdownWindow()
                        lockdown.show(reason: "Runtime tamper detected: \(reason)")
                    }
                    return
                }
            }
        }
        timer.resume()
        periodicTimer = timer
        print("[RuntimeShield] Periodic checks started (30s interval)")
    }

    static func stopPeriodicChecks() {
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    // MARK: - DYLD Injection Detection

    /// Check for DYLD_INSERT_LIBRARIES environment variable.
    /// Hardened Runtime should block this, but defense-in-depth catches edge cases.
    private static func checkDYLDInjection() -> CheckResult {
        let dangerousVars = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_FORCE_FLAT_NAMESPACE",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH"
        ]

        for envVar in dangerousVars {
            if let value = ProcessInfo.processInfo.environment[envVar], !value.isEmpty {
                return .failed("DYLD injection detected: \(envVar)=\(value.prefix(100))")
            }
        }

        return .passed
    }

    // MARK: - Debugger Detection

    /// Check if a debugger is attached via sysctl P_TRACED flag.
    private static func checkDebuggerAttached() -> CheckResult {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else {
            // Can't query — suspicious but don't lock out
            print("[RuntimeShield] sysctl failed — cannot check debugger status")
            return .passed
        }

        let isBeingTraced = (info.kp_proc.p_flag & P_TRACED) != 0
        if isBeingTraced {
            return .failed("Debugger attached to process (P_TRACED flag set)")
        }

        return .passed
    }

    // MARK: - Library Validation

    /// Enumerate loaded dylibs and flag any not from trusted locations.
    private static func checkLoadedLibraries() -> CheckResult {
        let trustedPrefixes = [
            "/usr/lib/",
            "/System/",
            "/Library/Apple/",
            "/AppleInternal/",        // Apple internal builds
        ]

        // App bundle frameworks path
        let bundleFrameworks = Bundle.main.privateFrameworksPath ?? ""
        let bundlePath = Bundle.main.bundlePath

        var suspiciousLibraries: [String] = []

        let imageCount = _dyld_image_count()
        for i in 0..<imageCount {
            guard let namePtr = _dyld_get_image_name(i) else { continue }
            let name = String(cString: namePtr)

            // Skip if from trusted system locations
            let isTrusted = trustedPrefixes.contains { name.hasPrefix($0) }
            let isFromBundle = !bundlePath.isEmpty && name.hasPrefix(bundlePath)
            let isFromBundleFrameworks = !bundleFrameworks.isEmpty && name.hasPrefix(bundleFrameworks)

            if !isTrusted && !isFromBundle && !isFromBundleFrameworks {
                // Also allow Xcode-injected libraries in dev (e.g. AddressSanitizer)
                let isDevTool = name.contains("Xcode") || name.contains("DeveloperTools")
                    || name.contains("libclang") || name.contains("Instruments")
                if !isDevTool {
                    suspiciousLibraries.append(name)
                }
            }
        }

        if !suspiciousLibraries.isEmpty {
            let list = suspiciousLibraries.prefix(5).joined(separator: ", ")
            return .failed("Unauthorized libraries loaded: \(list)")
        }

        return .passed
    }

    // MARK: - Status for Dashboard

    /// Whether periodic checks are currently active.
    static var isPeriodicActive: Bool {
        periodicTimer != nil
    }

    /// Human-readable status for the security dashboard.
    static func statusSummary() -> String {
        let env = AppModel.buildEnvironment
        switch env {
        case .debug: return "Skipped (debug build)"
        case .development: return "Warnings only (development)"
        case .release:
            return isPeriodicActive ? "Active (checking every 30s)" : "Initial check passed"
        }
    }
}
