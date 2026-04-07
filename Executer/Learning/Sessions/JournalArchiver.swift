import Foundation

/// Background job that manages the journal lifecycle:
/// - Journals older than 30 days: status → archived
/// - Archived journals older than 90 days: deleted (entries + journal)
///
/// Runs on a 24-hour timer. Also runs once on start to catch up
/// if the app was closed for a while.
final class JournalArchiver {
    static let shared = JournalArchiver()

    private var timer: Timer?
    private let archiveAfterDays = 30
    private let purgeAfterDays = 90
    private let checkInterval: TimeInterval = 86400  // 24 hours

    private init() {}

    /// Start the archiver. Runs an immediate check, then schedules periodic checks.
    func start() {
        // Run immediately to catch up
        performMaintenance()

        // Schedule periodic checks
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }

        print("[JournalArchiver] Started — archive after \(archiveAfterDays)d, purge after \(purgeAfterDays)d")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run the archive + purge cycle.
    private func performMaintenance() {
        let archived = JournalStore.shared.archiveOldJournals(olderThanDays: archiveAfterDays)
        let purged = JournalStore.shared.purgeArchivedJournals(olderThanDays: purgeAfterDays)

        if archived > 0 || purged > 0 {
            print("[JournalArchiver] Maintenance: archived \(archived) journals, purged \(purged) journals")
        }
    }
}
