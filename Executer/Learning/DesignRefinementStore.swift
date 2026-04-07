import Foundation

/// A single design refinement learned from comparing generated PPTs against user references.
struct DesignRefinement: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var category: String          // "color", "font", "layout", "spacing", "style"
    var observation: String       // Human-readable rule: "User prefers #2563EB accent"
    var referenceValue: String?   // What the user's sample has
    var generatedValue: String?   // What we produced
    var confidence: Double        // 0.0-1.0, increases with repeated observations
    var occurrenceCount: Int      // How many times this mismatch was seen
}

/// Persistent store for design refinements learned from post-PPT-creation reflection.
/// Accumulated learnings get injected into future PPT creation via prompt and engine overrides.
final class DesignRefinementStore {
    static let shared = DesignRefinementStore()

    private let storageURL: URL
    private let lock = NSLock()
    private(set) var refinements: [DesignRefinement] = []
    private static let maxRefinements = 50

    private init() {
        let appSupport = URL.applicationSupportDirectory
        storageURL = appSupport.appendingPathComponent("Executer/design_refinements.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([DesignRefinement].self, from: data) else { return }
        refinements = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(refinements) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    // MARK: - Add / Merge

    /// Add a refinement, merging with existing if category + referenceValue match.
    func add(_ refinement: DesignRefinement) {
        lock.lock()
        defer { lock.unlock() }

        // Merge: same category + same reference value → boost existing
        if let idx = refinements.firstIndex(where: {
            $0.category == refinement.category && $0.referenceValue == refinement.referenceValue
        }) {
            refinements[idx].occurrenceCount += 1
            refinements[idx].confidence = min(1.0, refinements[idx].confidence + 0.15)
            refinements[idx].generatedValue = refinement.generatedValue
            refinements[idx].observation = refinement.observation
        } else {
            refinements.append(refinement)
        }

        // Enforce cap — evict lowest confidence
        if refinements.count > Self.maxRefinements {
            refinements.sort { $0.confidence > $1.confidence }
            refinements = Array(refinements.prefix(Self.maxRefinements))
        }

        save()
    }

    /// Add multiple refinements at once.
    func addAll(_ newRefinements: [DesignRefinement]) {
        for r in newRefinements { add(r) }
    }

    // MARK: - System Prompt Injection

    /// Returns a formatted section for the system prompt (~500 chars max).
    func promptSection() -> String {
        lock.lock()
        let current = refinements
        lock.unlock()

        guard !current.isEmpty else { return "" }

        // Sort by confidence (highest first), take top entries
        let top = current.sorted { $0.confidence > $1.confidence }.prefix(10)

        var lines = ["\n## Design Refinements (learned from past PPT creations)"]
        lines.append("CRITICAL: Apply these rules when creating presentations. They reflect the user's actual style preferences.\n")

        // Group by category
        let grouped = Dictionary(grouping: top, by: { $0.category })
        for (category, items) in grouped.sorted(by: { $0.key < $1.key }) {
            let rules = items.map { r in
                let count = r.occurrenceCount > 1 ? " [confirmed \(r.occurrenceCount)x]" : ""
                return "- \(r.observation)\(count)"
            }.joined(separator: "\n")
            lines.append("**\(category.capitalized):** \n\(rules)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Engine Override

    /// Patch a design_language.json with learned refinements, writing to a temp file.
    /// Returns the temp file path, or nil if no refinements apply.
    func patchDesignLanguage(originalPath: String) -> String? {
        lock.lock()
        let current = refinements
        lock.unlock()

        // Only patch with high-confidence refinements
        let confident = current.filter { $0.confidence >= 0.4 }
        guard !confident.isEmpty else { return nil }

        // Load original
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: originalPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var ds = json["design_system"] as? [String: Any] ?? [:]
        var semantic = ds["semantic_colors"] as? [String: String] ?? [:]
        var typography = ds["typography"] as? [String: Any] ?? [:]

        for refinement in confident {
            guard let refValue = refinement.referenceValue else { continue }

            switch refinement.category {
            case "color":
                // Map color refinements to semantic color keys
                let obs = refinement.observation.lowercased()
                if obs.contains("accent") { semantic["accent"] = refValue }
                else if obs.contains("background") || obs.contains("bg") { semantic["background"] = refValue }
                else if obs.contains("text") && obs.contains("primary") { semantic["text_primary"] = refValue }
                else if obs.contains("text") && obs.contains("secondary") { semantic["text_secondary"] = refValue }

            case "font":
                // Override primary font
                if var fonts = typography["fonts_by_frequency"] as? [[String: Any]] {
                    if fonts.isEmpty {
                        fonts.append(["font": refValue, "uses": 999])
                    } else {
                        fonts[0]["font"] = refValue
                        fonts[0]["uses"] = 999
                    }
                    typography["fonts_by_frequency"] = fonts
                } else {
                    typography["fonts_by_frequency"] = [["font": refValue, "uses": 999]]
                }

            default:
                break
            }
        }

        ds["semantic_colors"] = semantic
        ds["typography"] = typography
        json["design_system"] = ds

        // Write to temp file
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("design_language_patched_\(UUID().uuidString).json")
        guard let patchedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return nil }
        try? patchedData.write(to: tempPath, options: .atomic)

        return tempPath.path
    }
}
