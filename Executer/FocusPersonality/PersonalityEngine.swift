import SwiftUI

struct PersonalityConfig {
    let systemPromptModifier: String
    let animationSpeed: Double     // 1.0 = normal, 0.5 = slower, 2.0 = faster
    let opacity: Double            // 0.0-1.0, background opacity adjustment
    let accentColor: Color
    let verbosity: String          // "concise", "normal", "detailed"
    let stripPleasantries: Bool
}

class PersonalityEngine {
    static let shared = PersonalityEngine()

    private var userOverrides: [String: PersonalityOverride] = [:]

    private init() {
        loadUserOverrides()
    }

    // MARK: - Current Personality

    var currentPersonality: PersonalityConfig {
        configFor(FocusStateService.shared.currentFocus)
    }

    func systemPromptSection() -> String {
        let modifier = currentPersonality.systemPromptModifier
        guard !modifier.isEmpty else { return "" }
        return "\n\n\(modifier)"
    }

    func postFilterResponse(_ text: String) -> String {
        var result = text

        // Always strip pleasantries — regardless of focus mode
        let pleasantries = [
            "Sure!", "Sure thing!", "Of course!", "Absolutely!",
            "Great question!", "Good question!", "Happy to help!",
            "Certainly!", "No problem!", "You're welcome!",
            "Sure,", "Of course,", "Absolutely,", "Certainly,",
            "I'll ", "I've ", "Let me ", "Here's what I ",
            "I can help ", "I'd be happy to ", "Here you go!",
            "Here you go,", "Here you go — ", "Here's ",
        ]

        for phrase in pleasantries {
            if result.hasPrefix(phrase) {
                result = String(result.dropFirst(phrase.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Capitalize first letter after stripping
                if let first = result.first, first.isLowercase {
                    result = first.uppercased() + result.dropFirst()
                }
                break  // Only strip the first one
            }
        }

        return result
    }

    // MARK: - Mode → Config Mapping

    private func configFor(_ mode: FocusMode) -> PersonalityConfig {
        // Check user overrides first
        if let override = userOverrides[mode.displayName.lowercased()] {
            return override.toConfig()
        }

        switch mode {
        case .none:
            return PersonalityConfig(
                systemPromptModifier: "",
                animationSpeed: 1.0,
                opacity: 1.0,
                accentColor: .accentColor,
                verbosity: "normal",
                stripPleasantries: false
            )

        case .work:
            return PersonalityConfig(
                systemPromptModifier: """
                The user is in Work Focus mode. Be extremely concise and direct. \
                Skip all pleasantries, filler, and preamble. Lead with the action or answer. \
                No emoji. Prioritize speed and clarity. If you can say it in fewer words, do so.
                """,
                animationSpeed: 1.5,
                opacity: 0.95,
                accentColor: .blue,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .reading:
            return PersonalityConfig(
                systemPromptModifier: """
                The user is in Reading Focus mode. Minimize interruptions. \
                Keep responses very brief unless the user asks for detail. \
                Do not volunteer extra information. Be precise and quiet.
                """,
                animationSpeed: 0.8,
                opacity: 0.85,
                accentColor: .indigo,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .personalTime:
            return PersonalityConfig(
                systemPromptModifier: """
                The user is relaxing. Be friendly and conversational. \
                You can use casual language and a warm tone.
                """,
                animationSpeed: 1.0,
                opacity: 1.0,
                accentColor: .green,
                verbosity: "normal",
                stripPleasantries: false
            )

        case .mindfulness:
            return PersonalityConfig(
                systemPromptModifier: """
                The user is in a mindfulness session. Be extremely brief and calm. \
                One sentence responses max. Do not ask follow-up questions. \
                Only respond to what was asked, nothing more.
                """,
                animationSpeed: 0.5,
                opacity: 0.8,
                accentColor: .teal,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .reduceInterruptions:
            return PersonalityConfig(
                systemPromptModifier: """
                The user wants fewer interruptions. Be concise. \
                Only surface important information. Skip optional details.
                """,
                animationSpeed: 1.0,
                opacity: 0.9,
                accentColor: .orange,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .sleep:
            return PersonalityConfig(
                systemPromptModifier: """
                The user has Sleep Focus on. Ultra-brief responses only. \
                Keep everything dim-friendly and minimal. One sentence max.
                """,
                animationSpeed: 0.5,
                opacity: 0.7,
                accentColor: .gray,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .doNotDisturb:
            return PersonalityConfig(
                systemPromptModifier: """
                The user has Do Not Disturb enabled. Be concise and direct. \
                No unnecessary elaboration.
                """,
                animationSpeed: 1.0,
                opacity: 0.9,
                accentColor: .accentColor,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .driving:
            return PersonalityConfig(
                systemPromptModifier: """
                The user is driving. Safety first. Refuse any task that requires \
                sustained visual attention. One-sentence responses only. \
                If the request is dangerous while driving, say so.
                """,
                animationSpeed: 1.0,
                opacity: 1.0,
                accentColor: .red,
                verbosity: "concise",
                stripPleasantries: true
            )

        case .custom:
            // Custom modes default to Work-like behavior
            return PersonalityConfig(
                systemPromptModifier: """
                The user has a custom Focus mode active (\(mode.displayName)). \
                Be concise and professional.
                """,
                animationSpeed: 1.0,
                opacity: 0.95,
                accentColor: .accentColor,
                verbosity: "concise",
                stripPleasantries: false
            )
        }
    }

    // MARK: - User Overrides

    private struct PersonalityOverride: Codable {
        let systemPromptModifier: String?
        let animationSpeed: Double?
        let opacity: Double?
        let verbosity: String?
        let stripPleasantries: Bool?

        func toConfig() -> PersonalityConfig {
            PersonalityConfig(
                systemPromptModifier: systemPromptModifier ?? "",
                animationSpeed: animationSpeed ?? 1.0,
                opacity: opacity ?? 1.0,
                accentColor: .accentColor,
                verbosity: verbosity ?? "normal",
                stripPleasantries: stripPleasantries ?? false
            )
        }
    }

    private func loadUserOverrides() {
        let configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer/focus_personality.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        do {
            let data = try Data(contentsOf: configURL)
            userOverrides = try JSONDecoder().decode([String: PersonalityOverride].self, from: data)
            print("[Personality] Loaded \(userOverrides.count) user overrides")
        } catch {
            print("[Personality] Failed to load user overrides: \(error)")
        }
    }
}
