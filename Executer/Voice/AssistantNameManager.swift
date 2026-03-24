import Foundation

/// Manages the assistant's name and generates flexible wake/address phrases.
/// Also stores transcription variants learned during voice calibration.
class AssistantNameManager {
    static let shared = AssistantNameManager()

    private let nameKey = "assistant_name"
    private let variantsKey = "assistant_name_variants"

    var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "Pip" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    /// Transcription variants learned during calibration — how SFSpeechRecognizer
    /// actually hears the user say the name (varies per accent/voice).
    var learnedVariants: [String] {
        get { UserDefaults.standard.stringArray(forKey: variantsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: variantsKey) }
    }

    /// Add a new variant learned from calibration.
    func addLearnedVariant(_ variant: String) {
        let lower = variant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return }
        var current = learnedVariants
        if !current.contains(lower) {
            current.append(lower)
            learnedVariants = current
        }
    }

    /// Clear learned variants (called when name changes).
    func clearLearnedVariants() {
        learnedVariants = []
    }

    /// All phrases that should be stripped from the beginning of a voice command.
    /// e.g., if user says "Pip play some music", we strip "Pip" and submit "play some music".
    func addressPrefixes() -> [String] {
        let n = name.lowercased()
        var prefixes = [
            n,
            "hey \(n)",
            "help \(n)",
            "\(n) bro",
            "yo \(n)",
            "ok \(n)",
            "okay \(n)",
        ]

        // Also add learned variants as prefixes
        for variant in learnedVariants {
            prefixes.append(variant)
            prefixes.append("hey \(variant)")
            prefixes.append("help \(variant)")
            prefixes.append("\(variant) bro")
        }

        // Sort longest first so we strip the most specific match
        return prefixes.sorted { $0.count > $1.count }
    }

    /// Strip any assistant name prefix from the command text.
    func stripNamePrefix(from command: String) -> String {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in addressPrefixes() {
            if lower.hasPrefix(prefix) {
                let stripped = command
                    .dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? command : stripped
            }
        }
        return command
    }
}
