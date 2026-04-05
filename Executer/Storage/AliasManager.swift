import Foundation

/// Manages quick command aliases — shortcuts that expand to full commands.
class AliasManager {
    static let shared = AliasManager()

    struct Alias: Codable {
        let trigger: String
        let expansion: String
    }

    private(set) var aliases: [Alias] = []

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aliases.json")
    }()

    private init() {
        load()
        print("[Aliases] Loaded \(aliases.count) aliases")
    }

    /// Resolve an input string — returns the expansion if it matches an alias trigger, otherwise passthrough.
    func resolve(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = aliases.first(where: { $0.trigger.lowercased() == trimmed.lowercased() }) {
            print("[Aliases] Resolved '\(trimmed)' → '\(alias.expansion)'")
            return alias.expansion
        }
        return input
    }

    func add(trigger: String, expansion: String) {
        // Remove existing with same trigger
        aliases.removeAll { $0.trigger.lowercased() == trigger.lowercased() }
        aliases.append(Alias(trigger: trigger, expansion: expansion))
        save()
        print("[Aliases] Added: '\(trigger)' → '\(expansion)'")
    }

    func remove(trigger: String) -> Bool {
        let before = aliases.count
        aliases.removeAll { $0.trigger.lowercased() == trigger.lowercased() }
        if aliases.count < before {
            save()
            return true
        }
        return false
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(aliases)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[Aliases] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            aliases = try JSONDecoder().decode([Alias].self, from: data)
        } catch {
            print("[Aliases] Failed to load: \(error)")
        }
    }
}

// MARK: - Alias Tools

struct CreateAliasTool: ToolDefinition {
    let name = "create_alias"
    let description = "Create a command alias — a short trigger that expands to a full command. E.g. 'dm' → 'toggle dark mode'."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "trigger": JSONSchema.string(description: "The short alias trigger (e.g. 'dm')"),
            "expansion": JSONSchema.string(description: "The full command it expands to (e.g. 'toggle dark mode')"),
        ], required: ["trigger", "expansion"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let trigger = try requiredString("trigger", from: args)
        let expansion = try requiredString("expansion", from: args)
        AliasManager.shared.add(trigger: trigger, expansion: expansion)
        return "Created alias: '\(trigger)' → '\(expansion)'"
    }
}

struct ListAliasesTool: ToolDefinition {
    let name = "list_aliases"
    let description = "List all command aliases."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let aliases = AliasManager.shared.aliases
        if aliases.isEmpty {
            return "No aliases defined."
        }
        var lines = ["\(aliases.count) aliases:"]
        for alias in aliases {
            lines.append("  '\(alias.trigger)' → '\(alias.expansion)'")
        }
        return lines.joined(separator: "\n")
    }
}

struct RemoveAliasTool: ToolDefinition {
    let name = "remove_alias"
    let description = "Remove a command alias by its trigger."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "trigger": JSONSchema.string(description: "The alias trigger to remove"),
        ], required: ["trigger"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let trigger = try requiredString("trigger", from: args)
        if AliasManager.shared.remove(trigger: trigger) {
            return "Removed alias '\(trigger)'."
        }
        return "No alias found with trigger '\(trigger)'."
    }
}
