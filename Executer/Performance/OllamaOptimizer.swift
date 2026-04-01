import Foundation

/// Provides hardware-adaptive Ollama configuration based on SiliconProfile.
enum OllamaOptimizer {
    /// Returns the recommended Ollama model for the current hardware.
    static var recommendedModel: String {
        SiliconProfile.shared.recommendedOllamaModel
    }

    /// Returns optimal Ollama request options for the current hardware.
    static var optimalOptions: [String: Any] {
        let profile = SiliconProfile.shared
        var options: [String: Any] = [
            "temperature": 0.1,
            "num_predict": 100,
            "num_thread": profile.performanceCoreCount,
        ]

        switch profile.computeTier {
        case .base:
            options["num_ctx"] = 2048
            options["num_batch"] = 128
        case .mid:
            options["num_ctx"] = 4096
            options["num_batch"] = 256
        case .high:
            options["num_ctx"] = 8192
            options["num_batch"] = 512
        case .ultra:
            options["num_ctx"] = 16384
            options["num_batch"] = 512
        }

        return options
    }

    /// Returns recommended keep_alive duration for the current hardware.
    static var keepAliveDuration: String {
        switch SiliconProfile.shared.computeTier {
        case .base:  return "10m"
        case .mid:   return "30m"
        case .high:  return "60m"
        case .ultra: return "120m"
        }
    }

    /// Returns the maximum number of models to keep loaded simultaneously.
    static var maxLoadedModels: Int {
        switch SiliconProfile.shared.computeTier {
        case .base, .mid: return 1
        case .high:       return 2
        case .ultra:      return 3
        }
    }
}
