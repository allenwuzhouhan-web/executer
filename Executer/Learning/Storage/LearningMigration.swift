import Foundation

/// Handles one-time migration from legacy per-app JSON files to SQLite.
/// After successful migration, the JSON files are deleted.
enum LearningMigration {

    /// Migrates legacy JSON profiles to the SQLite database.
    /// Safe to call multiple times — checks if migration is needed.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir = appSupport
            .appendingPathComponent(LearningConstants.appSupportSubdirectory, isDirectory: true)
            .appendingPathComponent(LearningConstants.legacyJSONSubdirectory, isDirectory: true)

        // Check if legacy directory exists and has JSON files
        guard fm.fileExists(atPath: legacyDir.path),
              let files = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.pathExtension == "json" }) else {
            return
        }

        print("[LearningMigration] Found legacy JSON files, migrating to SQLite...")

        var migratedCount = 0
        var patternCount = 0
        var observationCount = 0

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let profile = try JSONDecoder().decode(AppLearningProfile.self, from: data)

                // Migrate observations (recent actions)
                if !profile.recentActions.isEmpty {
                    LearningDatabase.shared.insertObservations(profile.recentActions)
                    observationCount += profile.recentActions.count
                }

                // Migrate patterns
                for pattern in profile.patterns {
                    LearningDatabase.shared.insertOrUpdatePattern(pattern)
                    patternCount += 1
                }

                // Delete the migrated JSON file
                try fm.removeItem(at: file)
                migratedCount += 1

            } catch {
                print("[LearningMigration] Failed to migrate \(file.lastPathComponent): \(error)")
            }
        }

        // Remove the legacy directory if empty
        if let remaining = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try? fm.removeItem(at: legacyDir)
        }

        print("[LearningMigration] Migrated \(migratedCount) apps (\(observationCount) observations, \(patternCount) patterns)")
    }
}
