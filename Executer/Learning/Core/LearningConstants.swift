import Foundation

/// Central repository of all Learning module constants.
/// Tuning these values adjusts observation, extraction, and storage behavior.
enum LearningConstants {

    // MARK: - Observation

    /// Buffer flush interval in seconds
    static let bufferFlushInterval: TimeInterval = 30

    /// Auto-flush when buffer reaches this size
    static let bufferFlushThreshold = 50

    /// Maximum value length captured from text edits (chars)
    static let maxValueLength = 200

    /// Screen reader max traversal depth
    static let maxUITreeDepth = 12

    /// Max UI elements in LLM summary
    static let maxUIElementsInSummary = 80

    /// Screen text value truncation length
    static let maxScreenValueLength = 500

    // MARK: - Pattern Extraction

    /// Minimum action sequence length to consider as a pattern
    static let minPatternLength = 3

    /// Maximum sliding window length for pattern detection
    static let maxPatternLength = 8

    /// Minimum occurrences to save a pattern
    static let minPatternFrequency = 2

    /// Maximum patterns stored per app
    static let maxPatternsPerApp = 20

    /// Maximum recent observations kept per app (for pattern extraction)
    static let maxRecentObservations = 500

    /// Pattern extraction interval in seconds
    static let patternExtractionInterval: TimeInterval = 300

    /// Similarity threshold for merging patterns (0.0–1.0)
    static let patternSimilarityThreshold = 0.8

    /// Max patterns included in LLM prompt per app
    static let maxPatternsInPrompt = 10

    // MARK: - Storage

    /// SQLite database filename
    static let databaseFilename = "learning.db"

    /// Application Support subdirectory
    static let appSupportSubdirectory = "Executer"

    /// Legacy JSON storage subdirectory (for migration)
    static let legacyJSONSubdirectory = "app_patterns"

    /// Observation retention period in days
    static let observationRetentionDays = 7

    // MARK: - Performance (M-Series Adaptive)

    /// Base batch size for observation processing
    static let baseBatchSize = 50

    /// Adaptive batch size based on available cores
    static var adaptiveBatchSize: Int {
        let cores = ProcessInfo.processInfo.processorCount
        // M5: ~10 cores → 50, M5Pro: ~14 → 100, M5Max: ~16 → 100, M5Ultra: ~32 → 200
        if cores >= 28 { return 200 }
        if cores >= 12 { return 100 }
        return baseBatchSize
    }

    /// Base session cache size
    static let baseSessionCacheSize = 1000

    /// Adaptive session cache based on available memory
    static var adaptiveSessionCacheSize: Int {
        let memGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        // M5: 16-24GB → 1000, M5Pro: 18-36GB → 2500, M5Max: 36-128GB → 5000, M5Ultra: 192+GB → 10000
        if memGB >= 128 { return 10000 }
        if memGB >= 36 { return 5000 }
        if memGB >= 18 { return 2500 }
        return baseSessionCacheSize
    }
}
