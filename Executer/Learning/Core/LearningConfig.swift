import Foundation

/// UserDefaults-backed configuration for the Learning module.
/// Provides per-feature toggles so users can control what's active.
final class LearningConfig {
    static let shared = LearningConfig()

    private let defaults = UserDefaults.standard

    private init() {
        // Set defaults for new installs
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.learningEnabled: true,
            Keys.observationEnabled: true,
            Keys.patternExtractionEnabled: true,
            Keys.screenSamplingEnabled: true,
            Keys.screenSamplingInterval: 60.0,
            Keys.contextInjectionEnabled: true,
        ])
    }

    // MARK: - Keys

    private enum Keys {
        static let learningEnabled = "learning_enabled"
        static let observationEnabled = "learning_observation_enabled"
        static let patternExtractionEnabled = "learning_pattern_extraction_enabled"
        static let screenSamplingEnabled = "learning_screen_sampling_enabled"
        static let screenSamplingInterval = "learning_screen_sampling_interval"
        static let contextInjectionEnabled = "learning_context_injection_enabled"
    }

    // MARK: - Properties

    /// Master toggle for the entire Learning module
    var isLearningEnabled: Bool {
        get { defaults.bool(forKey: Keys.learningEnabled) }
        set { defaults.set(newValue, forKey: Keys.learningEnabled) }
    }

    /// Toggle for background action observation
    var isObservationEnabled: Bool {
        get { defaults.bool(forKey: Keys.observationEnabled) }
        set { defaults.set(newValue, forKey: Keys.observationEnabled) }
    }

    /// Toggle for pattern extraction from observations
    var isPatternExtractionEnabled: Bool {
        get { defaults.bool(forKey: Keys.patternExtractionEnabled) }
        set { defaults.set(newValue, forKey: Keys.patternExtractionEnabled) }
    }

    /// Toggle for periodic screen text sampling
    var isScreenSamplingEnabled: Bool {
        get { defaults.bool(forKey: Keys.screenSamplingEnabled) }
        set { defaults.set(newValue, forKey: Keys.screenSamplingEnabled) }
    }

    /// Interval for screen text sampling in seconds
    var screenSamplingInterval: TimeInterval {
        get { defaults.double(forKey: Keys.screenSamplingInterval) }
        set { defaults.set(newValue, forKey: Keys.screenSamplingInterval) }
    }

    /// Toggle for injecting learned context into LLM prompts (saves tokens when off)
    var isContextInjectionEnabled: Bool {
        get { defaults.bool(forKey: Keys.contextInjectionEnabled) }
        set { defaults.set(newValue, forKey: Keys.contextInjectionEnabled) }
    }
}
