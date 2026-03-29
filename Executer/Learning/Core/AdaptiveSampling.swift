import Foundation

/// Manages adaptive sampling rates based on learning maturity and active app.
/// First week: aggressive 5-10s sampling to learn fast.
/// After first week: relaxes to 30-60s but boosts for key apps.
final class AdaptiveSampling {
    static let shared = AdaptiveSampling()

    /// Current effective sampling interval in seconds.
    private(set) var currentInterval: TimeInterval = 10

    /// App currently getting boosted sampling.
    private var boostedApp: String?
    private var boostTimer: Timer?

    /// How long app-specific boosts last (seconds).
    private let boostDuration: TimeInterval = 600  // 10 minutes per boost

    private init() {
        recalculateInterval()
    }

    // MARK: - Interval Calculation

    /// Recalculate the sampling interval based on learning age and context.
    func recalculateInterval() {
        let daysSinceStart = SmartLaunchDetector.shared.daysSinceLearningStarted

        if daysSinceStart < 1 {
            // Day 1: Maximum intensity — learn everything
            currentInterval = 5
        } else if daysSinceStart < 3 {
            // Days 2-3: Still very aggressive
            currentInterval = 8
        } else if daysSinceStart < 7 {
            // Days 4-7: Moderate intensity
            currentInterval = 15
        } else if daysSinceStart < 14 {
            // Week 2: Relaxing
            currentInterval = 30
        } else if daysSinceStart < 30 {
            // Month 1: Standard
            currentInterval = 45
        } else {
            // After month 1: Maintenance mode
            currentInterval = 60
        }

        // Apply app boost if active
        if boostedApp != nil {
            currentInterval = min(currentInterval, 8) // Never slower than 8s during boost
        }

        // Update the config
        LearningConfig.shared.screenSamplingInterval = currentInterval
    }

    /// Boost sampling rate for a specific app (e.g., when PowerPoint launches).
    func boostForApp(_ appName: String) {
        boostedApp = appName
        recalculateInterval()

        // Auto-expire the boost
        boostTimer?.invalidate()
        boostTimer = Timer.scheduledTimer(withTimeInterval: boostDuration, repeats: false) { [weak self] _ in
            self?.endBoost()
        }

        print("[AdaptiveSampling] Boosted to \(currentInterval)s for \(appName)")
    }

    /// End the current boost.
    func endBoost() {
        boostedApp = nil
        boostTimer?.invalidate()
        boostTimer = nil
        recalculateInterval()
        print("[AdaptiveSampling] Boost ended, interval: \(currentInterval)s")
    }

    /// Get a human-readable description of current sampling state.
    func statusDescription() -> String {
        let days = SmartLaunchDetector.shared.daysSinceLearningStarted
        let phase: String
        if days < 1 { phase = "Day 1 (maximum intensity)" }
        else if days < 3 { phase = "Days 2-3 (aggressive)" }
        else if days < 7 { phase = "First week (moderate)" }
        else if days < 14 { phase = "Week 2 (relaxing)" }
        else if days < 30 { phase = "Month 1 (standard)" }
        else { phase = "Maintenance" }

        var status = "Sampling: \(Int(currentInterval))s | Phase: \(phase) | Day \(days)"
        if let app = boostedApp {
            status += " | Boosted for \(app)"
        }
        return status
    }
}
