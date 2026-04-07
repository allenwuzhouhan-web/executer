import Foundation

/// Bridge between TrustManager's score tracking and SecurityGateway's approval flow.
/// Uses deterministic UUIDs from capability+domain strings to map onto TrustManager's UUID-based API.
enum TrustRatchet {
    enum Capability {
        static let fileOrganize = "file_organize"
        static let fileMove = "file_move"
        static let presentationComplete = "presentation_complete"
        static let documentComplete = "document_complete"
        static let emailDraft = "email_draft"
        static let webResearch = "web_research"
    }

    /// Generate a deterministic UUID from a capability+domain string.
    private static func capabilityUUID(_ capability: String, _ domain: String) -> UUID {
        let key = "cap:\(capability):\(domain)"
        let data = Data(key.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in data.prefix(16).enumerated() { bytes[i] = byte }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func shouldAutoApprove(capability: String, domain: String) -> Bool {
        TrustManager.shared.canAutoApprove(templateId: capabilityUUID(capability, domain))
    }

    static func recordSuccess(capability: String, domain: String) {
        TrustManager.shared.recordSuccess(templateId: capabilityUUID(capability, domain))
    }

    static func recordFailure(capability: String, domain: String) {
        TrustManager.shared.recordFailure(templateId: capabilityUUID(capability, domain))
    }

    static func trustReport() -> String {
        "Trust Ratchet active — tracks per-capability trust via TrustManager."
    }

    static func canBypassRiskAssessment(toolName: String, domain: String) -> Bool {
        let capability: String
        switch toolName {
        case "move_file", "copy_file": capability = Capability.fileMove
        case "create_presentation": capability = Capability.presentationComplete
        case "create_word_document", "create_document": capability = Capability.documentComplete
        case "search_web", "browser_extract": capability = Capability.webResearch
        default: return false
        }
        return TrustManager.shared.canAutoApprove(templateId: capabilityUUID(capability, domain))
    }
}
