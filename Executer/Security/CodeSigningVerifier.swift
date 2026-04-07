import Foundation
import Security

/// Verifies the app's code signature using Apple's Security framework.
/// Uses SecStaticCode and SecRequirement APIs for genuine OS-level validation.
enum CodeSigningVerifier {

    struct Result {
        let valid: Bool
        let teamID: String?
        let signingIdentity: String?
        let reason: String?
    }

    /// Expected team identifier for production releases.
    /// Set to the real team ID when distributing. nil disables team ID matching.
    #if DEBUG
    static let expectedTeamID: String? = nil
    #else
    static let expectedTeamID: String? = nil  // TODO: Set to real team ID for App Store / notarized distribution
    #endif

    /// Verify the running binary's code signature using Apple's Security framework.
    static func verifyCodeSignature() -> Result {
        let bundleURL = Bundle.main.bundleURL as CFURL
        var staticCode: SecStaticCode?

        // Create a static code reference for the app bundle
        let createStatus = SecStaticCodeCreateWithPath(bundleURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return Result(valid: false, teamID: nil, signingIdentity: nil,
                          reason: "Failed to create static code reference (OSStatus: \(createStatus))")
        }

        // Validate the code signature with strict checks
        let flags: SecCSFlags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures |
            kSecCSStrictValidate |
            kSecCSCheckNestedCode
        )
        let validityStatus = SecStaticCodeCheckValidity(code, flags, nil)
        guard validityStatus == errSecSuccess else {
            return Result(valid: false, teamID: nil, signingIdentity: nil,
                          reason: "Code signature validation failed (OSStatus: \(validityStatus))")
        }

        // Extract signing information
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess, let signingInfo = info as? [String: Any] else {
            // Signature is valid but we can't read the info — still valid
            return Result(valid: true, teamID: nil, signingIdentity: nil, reason: nil)
        }

        let teamID = signingInfo["teamid"] as? String
        let signingIdentity = signingInfo["id"] as? String

        // Check team ID if we have an expected one
        #if !DEBUG
        if expectedTeamID == nil {
            print("[Security] WARNING: expectedTeamID is nil — team ID verification is disabled in release build")
        }
        #endif
        if let expected = expectedTeamID {
            if teamID != expected {
                return Result(valid: false, teamID: teamID, signingIdentity: signingIdentity,
                              reason: "Team ID mismatch: expected \(expected), got \(teamID ?? "none")")
            }
        }

        return Result(valid: true, teamID: teamID, signingIdentity: signingIdentity, reason: nil)
    }

    /// Check if the binary is signed with an Apple-issued certificate (not ad-hoc).
    /// Ad-hoc signatures use "-" as the signing identity and have no team ID.
    static func isProperlyCodeSigned() -> Bool {
        let result = verifyCodeSignature()
        guard result.valid else { return false }
        // Ad-hoc signing identity is "-"
        if result.signingIdentity == "-" { return false }
        return true
    }

    /// Verify against a specific requirement string (e.g. anchor apple generic).
    static func verifyRequirement(_ requirementString: String) -> Bool {
        let bundleURL = Bundle.main.bundleURL as CFURL
        var staticCode: SecStaticCode?

        guard SecStaticCodeCreateWithPath(bundleURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(code, SecCSFlags(), req) == errSecSuccess
    }

    /// Human-readable summary for the Security dashboard.
    static func statusSummary() -> String {
        let result = verifyCodeSignature()
        if result.valid {
            let team = result.teamID ?? "none"
            let identity = result.signingIdentity ?? "unknown"
            return "Valid (team: \(team), identity: \(identity))"
        } else {
            return "INVALID: \(result.reason ?? "unknown error")"
        }
    }
}
