import Foundation

/// Stores known contact names for MessageParser name resolution.
/// All messaging goes through WeChat — no platform routing needed.
class MessageRouter {
    static let shared = MessageRouter()

    /// Known contact names (persisted across sessions)
    private var knownContacts: Set<String> = []

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contact_routes.json")
    }()

    private init() {
        load()
    }

    /// Remember a contact name after a successful send
    func addContact(_ name: String) {
        guard !name.isEmpty else { return }
        knownContacts.insert(name)
        save()
    }

    /// All known contact names sorted alphabetically (used by MessageParser)
    func allContacts() -> [String] {
        Array(knownContacts).sorted()
    }

    // MARK: - Persistence (HMAC-protected)

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(knownContacts))
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
                    print("[SECURITY] Known contacts integrity check failed — resetting.")
                    knownContacts = []
                    return
                }
                // New format: array of strings
                if let contacts = try? JSONDecoder().decode([String].self, from: envelope.data) {
                    knownContacts = Set(contacts)
                }
                // Legacy format: dictionary with platform mappings — extract just the keys
                else if let legacy = try? JSONDecoder().decode([String: String].self, from: envelope.data) {
                    knownContacts = Set(legacy.keys)
                    save() // Re-save in new format
                }
            } else {
                // Legacy plaintext (no envelope)
                if let contacts = try? JSONDecoder().decode([String].self, from: rawData) {
                    knownContacts = Set(contacts)
                } else if let legacy = try? JSONDecoder().decode([String: String].self, from: rawData) {
                    knownContacts = Set(legacy.keys)
                }
                save()
            }
            print("[MessageRouter] Loaded \(knownContacts.count) known contacts")
        } catch {
            print("[MessageRouter] Failed to load: \(error)")
        }
    }
}
