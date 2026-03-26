import Foundation

/// Routes messages to iMessage or WeChat based on contact preferences and heuristics.
class MessageRouter {
    static let shared = MessageRouter()

    enum MessagePlatform: String, Codable {
        case imessage
        case wechat
    }

    /// Explicit contact → platform mappings set by the user
    private var contactRoutes: [String: MessagePlatform] = [:]

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contact_routes.json")
    }()

    private init() {
        load()
    }

    // MARK: - Routing

    /// Determine which platform to use for a contact.
    /// Returns nil if ambiguous (caller should ask the user).
    func route(contact: String, messageText: String) -> MessagePlatform? {
        // 1. Check explicit mapping (case-insensitive)
        let lower = contact.lowercased()
        if let explicit = contactRoutes.first(where: { $0.key.lowercased() == lower })?.value {
            return explicit
        }

        // 2. If contact name contains CJK characters → WeChat
        if containsCJK(contact) {
            return .wechat
        }

        // 3. If message is primarily Chinese → lean WeChat
        if primaryLanguageIsChinese(messageText) {
            return .wechat
        }

        // 4. Ambiguous — return nil so caller can ask the user
        return nil
    }

    /// Set a contact's preferred platform (persists across sessions)
    func setRoute(contact: String, platform: MessagePlatform) {
        contactRoutes[contact] = platform
        save()
        print("[MessageRouter] Set \(contact) → \(platform.rawValue)")
    }

    /// Remove a contact route
    func removeRoute(contact: String) {
        contactRoutes.removeValue(forKey: contact)
        save()
    }

    /// List all contact routes for display
    func allRoutes() -> [(contact: String, platform: MessagePlatform)] {
        contactRoutes.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Language Detection

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs + common ranges
            (0x4E00...0x9FFF).contains(scalar.value) ||    // CJK Unified
            (0x3400...0x4DBF).contains(scalar.value) ||    // CJK Extension A
            (0x3000...0x303F).contains(scalar.value) ||    // CJK Symbols
            (0x3040...0x309F).contains(scalar.value) ||    // Hiragana
            (0x30A0...0x30FF).contains(scalar.value) ||    // Katakana
            (0xAC00...0xD7AF).contains(scalar.value)       // Hangul
        }
    }

    private func primaryLanguageIsChinese(_ text: String) -> Bool {
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }.count
        let total = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard total > 0 else { return false }
        return Double(cjkCount) / Double(total) > 0.3
    }

    // MARK: - Persistence (HMAC-protected)

    private func save() {
        do {
            let data = try JSONEncoder().encode(contactRoutes)
            let hmac = SecureStorage.hmac(for: data)
            let envelope = IntegrityEnvelope(data: data, hmac: hmac)
            let envelopeData = try JSONEncoder().encode(envelope)
            try envelopeData.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            print("[MessageRouter] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let rawData = try Data(contentsOf: storageURL)
            if let envelope = try? JSONDecoder().decode(IntegrityEnvelope.self, from: rawData) {
                guard SecureStorage.verifyHMAC(envelope.hmac, for: envelope.data) else {
                    print("[SECURITY] Contact routes integrity check failed — resetting.")
                    contactRoutes = [:]
                    return
                }
                contactRoutes = try JSONDecoder().decode([String: MessagePlatform].self, from: envelope.data)
            } else {
                // Legacy plaintext
                contactRoutes = try JSONDecoder().decode([String: MessagePlatform].self, from: rawData)
                save()
            }
            print("[MessageRouter] Loaded \(contactRoutes.count) contact routes")
        } catch {
            print("[MessageRouter] Failed to load: \(error)")
        }
    }
}
