import Foundation

/// Manages persistence and CRUD for automation rules.
class AutomationRuleManager {
    static let shared = AutomationRuleManager()

    private(set) var rules: [AutomationRule] = []

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("automation_rules.json")
    }()

    private init() {
        load()
    }

    // MARK: - CRUD

    func addRule(_ rule: AutomationRule) {
        rules.append(rule)
        save()
        // Notify event bus to update time-based triggers
        SystemEventBus.shared.rulesDidChange()
    }

    func removeRule(id: String) {
        rules.removeAll { $0.id == id }
        save()
        SystemEventBus.shared.rulesDidChange()
    }

    func toggleRule(id: String) -> Bool? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        rules[index].enabled.toggle()
        save()
        SystemEventBus.shared.rulesDidChange()
        return rules[index].enabled
    }

    func markFired(id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].lastFiredAt = Date()
        save()
    }

    /// Returns enabled rules that match the given event and are not in cooldown.
    func matchingRules(for event: SystemEvent) -> [AutomationRule] {
        let now = Date()
        return rules.filter { rule in
            guard rule.enabled else { return false }

            // Check cooldown
            if let lastFired = rule.lastFiredAt,
               now.timeIntervalSince(lastFired) < Double(rule.cooldownSeconds) {
                return false
            }

            return triggerMatches(rule.trigger, event: event)
        }
    }

    private func triggerMatches(_ trigger: RuleTrigger, event: SystemEvent) -> Bool {
        switch (trigger, event) {
        case (.displayConnected, .displayCountChanged(let old, let new)):
            return new > old
        case (.displayDisconnected, .displayCountChanged(let old, let new)):
            return new < old
        case (.wifiConnected(let name), .wifiChanged(let newNetwork)):
            if let name = name {
                return newNetwork?.lowercased() == name.lowercased()
            }
            return newNetwork != nil
        case (.wifiDisconnected, .wifiChanged(let newNetwork)):
            return newNetwork == nil
        case (.timeOfDay(let h, let m), .timeReached(let eh, let em)):
            return h == eh && m == em
        case (.appLaunched(let app), .appLaunched(let name)):
            return app.lowercased() == name.lowercased()
        case (.appQuit(let app), .appQuit(let name)):
            return app.lowercased() == name.lowercased()
        case (.batteryLow(let threshold), .batteryLevel(let pct)):
            return pct <= threshold
        case (.powerConnected, .powerSourceChanged(let isAC)):
            return isAC
        case (.powerDisconnected, .powerSourceChanged(let isAC)):
            return !isAC
        case (.screenLocked, .screenLocked):
            return true
        case (.screenUnlocked, .screenUnlocked):
            return true
        case (.focusChanged(let mode), .focusChanged(let newMode)):
            if let mode = mode {
                return newMode?.lowercased() == mode.lowercased()
            }
            return true // any focus change
        default:
            return false
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(rules)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[Automation] Failed to save rules: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rules = try decoder.decode([AutomationRule].self, from: data)
            print("[Automation] Loaded \(rules.count) rules")
        } catch {
            print("[Automation] Failed to load rules: \(error)")
        }
    }
}
