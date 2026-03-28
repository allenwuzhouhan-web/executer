import Foundation
import AppKit

/// Orchestrates all learning: observes user actions, stores per-app profiles,
/// extracts patterns, and provides LLM-injectable context.
/// All data stays local in ~/Library/Application Support/Executer/app_patterns/.
class LearningManager {
    static let shared = LearningManager()

    private var profiles: [String: AppLearningProfile] = [:] // appName → profile
    private let storageDir: URL
    private var actionBuffer: [UserAction] = []
    private let bufferFlushInterval: TimeInterval = 30 // Flush every 30s
    private var flushTimer: Timer?
    private let extractionInterval: TimeInterval = 300 // Extract patterns every 5 min
    private var lastExtraction: Date = .distantPast

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "learning_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "learning_enabled") }
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("Executer/app_patterns", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Default to enabled
        if UserDefaults.standard.object(forKey: "learning_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "learning_enabled")
        }

        loadProfiles()
    }

    // MARK: - Start / Stop

    func start() {
        guard isEnabled else { return }

        AppObserver.shared.onAction = { [weak self] action in
            self?.recordAction(action)
        }
        AppObserver.shared.start()

        // Periodic flush timer
        flushTimer = Timer.scheduledTimer(withTimeInterval: bufferFlushInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }

        print("[Learning] Started — observing user workflows")
    }

    func stop() {
        AppObserver.shared.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        flushBuffer()
        saveProfiles()
        print("[Learning] Stopped")
    }

    // MARK: - Action Recording

    private func recordAction(_ action: UserAction) {
        actionBuffer.append(action)

        // Auto-flush if buffer gets large
        if actionBuffer.count >= 50 {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !actionBuffer.isEmpty else { return }

        let actions = actionBuffer
        actionBuffer.removeAll()

        for action in actions {
            let appName = action.appName
            if profiles[appName] == nil {
                profiles[appName] = AppLearningProfile(
                    appName: appName,
                    recentActions: [],
                    patterns: [],
                    totalActionsObserved: 0,
                    lastUpdated: Date()
                )
            }
            profiles[appName]?.recentActions.append(action)
            profiles[appName]?.totalActionsObserved += 1
        }

        // Periodically extract patterns
        if Date().timeIntervalSince(lastExtraction) > extractionInterval {
            extractAllPatterns()
            lastExtraction = Date()
        }

        saveProfiles()
    }

    // MARK: - Pattern Extraction

    private func extractAllPatterns() {
        for appName in profiles.keys {
            PatternLearner.shared.extractPatterns(from: &profiles[appName]!)
        }
        print("[Learning] Extracted patterns for \(profiles.count) apps")
    }

    // MARK: - LLM Context Injection

    /// Returns learned patterns for the specified app, formatted for LLM system prompt injection.
    func promptSection(forApp appName: String) -> String {
        guard let profile = profiles[appName], !profile.patterns.isEmpty else { return "" }
        return profile.promptSummary()
    }

    /// Returns learned patterns for the frontmost app.
    func promptSectionForFrontmostApp() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return "" }
        return promptSection(forApp: name)
    }

    /// Returns a summary of all learned apps and their pattern counts.
    func overallSummary() -> String {
        guard !profiles.isEmpty else { return "No app patterns learned yet." }

        var lines = ["Learned app patterns:"]
        for (name, profile) in profiles.sorted(by: { $0.value.totalActionsObserved > $1.value.totalActionsObserved }) {
            lines.append("  \(name): \(profile.patterns.count) patterns, \(profile.totalActionsObserved) actions observed")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns a full UI tree reading of the frontmost app (on-demand, not cached).
    func readCurrentScreen() -> String? {
        return ScreenReader.summarizeFrontmostApp()
    }

    // MARK: - Persistence

    private func loadProfiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let profile = try JSONDecoder().decode(AppLearningProfile.self, from: data)
                profiles[profile.appName] = profile
            } catch {
                print("[Learning] Failed to load \(file.lastPathComponent): \(error)")
            }
        }
        print("[Learning] Loaded \(profiles.count) app profiles")
    }

    private func saveProfiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (name, profile) in profiles {
            let safeName = name.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let file = storageDir.appendingPathComponent("\(safeName).json")
            do {
                let data = try encoder.encode(profile)
                try data.write(to: file, options: .atomic)
            } catch {
                print("[Learning] Failed to save \(name): \(error)")
            }
        }
    }

    // MARK: - Data Management

    /// Clears all learned data for a specific app.
    func clearApp(_ appName: String) {
        profiles.removeValue(forKey: appName)
        let safeName = appName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let file = storageDir.appendingPathComponent("\(safeName).json")
        try? FileManager.default.removeItem(at: file)
    }

    /// Clears all learned data.
    func clearAll() {
        profiles.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// List of all apps with learned profiles.
    var learnedApps: [(name: String, patternCount: Int, actionCount: Int)] {
        profiles.map { ($0.key, $0.value.patterns.count, $0.value.totalActionsObserved) }
            .sorted { $0.actionCount > $1.actionCount }
    }
}
