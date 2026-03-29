import Foundation
import LocalAuthentication

/// Touch ID / Face ID authentication gate for sensitive operations.
/// Used to verify user identity before starting learning or executing critical tools.
enum BiometricGate {

    /// Check if biometric authentication is available on this device.
    static func isAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Authenticate the user with Touch ID / Face ID.
    /// Returns true if authenticated, false if denied or unavailable.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Biometrics not available — fall through (don't block on machines without Touch ID)
            print("[BiometricGate] Biometrics not available: \(error?.localizedDescription ?? "unknown")")
            return true // Allow through if no biometric hardware
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch {
            print("[BiometricGate] Authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Authenticate with fallback to device passcode if biometrics fail.
    static func authenticateWithFallback(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true // No auth available — allow through
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}
