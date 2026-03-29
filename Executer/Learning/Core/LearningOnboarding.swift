import Foundation

/// One-time onboarding message when learning starts for the first time.
/// Explains that learning is free and everything the user does is useful.
enum LearningOnboarding {

    private static let hasShownKey = "learning_onboarding_shown"

    /// Check if onboarding has been shown.
    static var hasShown: Bool {
        UserDefaults.standard.bool(forKey: hasShownKey)
    }

    /// Show the onboarding message if it hasn't been shown yet.
    /// Posts a notification for the UI to pick up.
    static func showIfNeeded() {
        guard !hasShown else { return }
        UserDefaults.standard.set(true, forKey: hasShownKey)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .learningOnboarding,
                object: nil,
                userInfo: [
                    "title": "Learning is now active",
                    "message": """
                    Executer is learning how you work. Here's what you should know:

                    FREE — All observation runs locally on your Mac. No API calls, no cost. The teal glow means it's watching.

                    EVERYTHING COUNTS — Even "random" activities like browsing AoPS or studying math teach me your schedule, study habits, and app preferences. There are no wasted observations.

                    PATTERNS EMERGE — After a few days, I'll understand your workflows: when you study, how you build presentations, which apps you use together. The longer I watch, the better I get.

                    YOUR DATA — All data stays on your device, encrypted. You can see everything I've learned in Settings → Learning, and delete it anytime.

                    COST — Learning itself is free. The only cost is ~$0.002 extra per question when I use learned context to give you better answers.
                    """,
                ]
            )
        }

        print("[LearningOnboarding] First-time onboarding shown")
    }

    /// Reset onboarding (for testing).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: hasShownKey)
    }
}

extension Notification.Name {
    static let learningOnboarding = Notification.Name("com.executer.learningOnboarding")
}
