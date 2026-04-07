import Foundation

/// Runs daily to apply exponential decay to all beliefs (Principle 5).
/// Also handles garbage collection of noise beliefs and pruning old observations.
///
/// Decay function: confidence *= e^(-λ × days_since_last_observed)
/// where λ = ln(2)/14 — half-life of 14 days.
///
/// A pattern from 6 months ago with no recent reinforcement carries near-zero weight.
/// This prevents the system from being haunted by old, obsolete behaviors.
final class DecayEngine {
    static let shared = DecayEngine()

    private var dailyTimer: DispatchSourceTimer?
    private var lastRunDate: String = ""

    private init() {}

    /// Start the daily decay job. Runs once per calendar day.
    func start() {
        // Check if we should run immediately (missed yesterday's run)
        let today = todayString()
        let lastRun = UserDefaults.standard.string(forKey: "oe_decay_last_run") ?? ""
        if lastRun != today {
            runDecayJob()
        }

        // Schedule to check every hour — runs the job once per calendar day
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3600, repeating: 3600)  // Check every hour
        timer.setEventHandler { [weak self] in
            let today = self?.todayString() ?? ""
            let lastRun = UserDefaults.standard.string(forKey: "oe_decay_last_run") ?? ""
            if lastRun != today {
                self?.runDecayJob()
            }
        }
        timer.resume()
        dailyTimer = timer

        print("[DecayEngine] Started — daily decay job scheduled")
    }

    func stop() {
        dailyTimer?.cancel()
        dailyTimer = nil
    }

    /// Execute the full daily maintenance cycle.
    func runDecayJob() {
        let start = CFAbsoluteTimeGetCurrent()

        // 1. Apply exponential decay to all non-vetoed, non-boosted beliefs
        let reclassified = BeliefStore.shared.applyDecay()

        // 2. Garbage collect noise beliefs older than 30 days
        let garbageCollected = BeliefStore.shared.garbageCollectNoise(olderThanDays: 30)

        // 3. Prune old observations (> 30 days)
        ObservationStore.shared.pruneOldObservations(retentionDays: 30)

        // 4. Check database size — warn if getting large
        let obsSize = ObservationStore.shared.databaseSizeBytes()
        if obsSize > 1_073_741_824 {  // > 1 GB
            print("[DecayEngine] WARNING: observations.db is \(obsSize / 1_048_576)MB — triggering aggressive cleanup")
            ObservationStore.shared.pruneOldObservations(retentionDays: 14)
        } else if obsSize > 536_870_912 {  // > 500 MB
            print("[DecayEngine] Note: observations.db is \(obsSize / 1_048_576)MB")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let counts = BeliefStore.shared.beliefCount()

        print("[DecayEngine] Daily job complete in \(String(format: "%.1f", elapsed))s — " +
              "decayed \(reclassified) beliefs, GC'd \(garbageCollected) noise, " +
              "store: \(counts.beliefs) beliefs / \(counts.hypotheses) hypotheses / \(counts.noise) noise")

        // Mark today as done
        UserDefaults.standard.set(todayString(), forKey: "oe_decay_last_run")
    }

    private func todayString() -> String {
        BeliefStore.dayDateFormatter.string(from: Date())
    }
}
