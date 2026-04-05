import Foundation
import AppKit

// MARK: - WorkState

/// Fused understanding of the user's current activity, derived from the observation stream.
/// Lightweight, Sendable, and cheap to produce — no LLM calls involved.
struct WorkState: Sendable {
    let currentApp: String
    let windowTitle: String
    let activityType: ActivityType
    let activityStartTime: Date
    let recentApps: [AppDwell]
    let recentClipboardFlows: Int
    let recentFileEvents: Int
    let lastUserActionTime: Date
    let focusMode: FocusMode
    let timestamp: Date

    /// First 100 chars of last clipboard text (for enrichment suggestions). Empty if no text.
    let lastClipboardPreview: String

    /// Recent file extensions seen in the event window (e.g. ["pdf", "pdf", "docx"]).
    let recentFileExtensions: [String]

    struct AppDwell: Sendable {
        let name: String
        let seconds: Int
    }

    enum ActivityType: String, Sendable {
        case coding
        case writing
        case browsing
        case communicating
        case designing
        case presenting
        case reading
        case idle
        case unknown
    }

    static let empty = WorkState(
        currentApp: "",
        windowTitle: "",
        activityType: .idle,
        activityStartTime: Date(),
        recentApps: [],
        recentClipboardFlows: 0,
        recentFileEvents: 0,
        lastUserActionTime: .distantPast,
        focusMode: .none,
        timestamp: Date(),
        lastClipboardPreview: "",
        recentFileExtensions: []
    )

    /// Duration of the current activity in seconds.
    var activityDuration: TimeInterval {
        timestamp.timeIntervalSince(activityStartTime)
    }

    /// Seconds since last user action (for idle detection).
    var idleSeconds: TimeInterval {
        timestamp.timeIntervalSince(lastUserActionTime)
    }
}

// MARK: - WorkStateEngine

/// Fuses ObservationEvents from ContinuousPerceptionDaemon into a rolling WorkState.
///
/// Registers as a daemon consumer and maintains a 10-minute rolling window of events.
/// The snapshot is always available in O(1) — no computation on read.
actor WorkStateEngine {
    static let shared = WorkStateEngine()

    // MARK: - Configuration

    private let windowDuration: TimeInterval = 600  // 10-minute rolling window
    private let idleThreshold: TimeInterval = 60    // 60s no action = idle

    // MARK: - State

    private var currentState: WorkState = .empty
    private var currentApp: String = ""
    private var currentWindowTitle: String = ""
    private var lastUserActionTime: Date = .distantPast
    private var activityStartTime: Date = Date()
    private var lastActivityType: WorkState.ActivityType = .idle

    /// Cached focus mode (updated from system events to avoid MainActor access).
    private var cachedFocusMode: FocusMode = .none

    /// Rolling event window for counting recent events.
    private var recentClipboardTimes: [Date] = []
    private var recentFileTimes: [Date] = []

    /// Last clipboard text preview (first 100 chars).
    private var lastClipboardPreview: String = ""

    /// Recent file extensions from file events.
    private var recentFileExtensionLog: [(ext: String, time: Date)] = []

    /// App dwell tracking: app name → cumulative seconds in the window.
    private var appSwitchLog: [(app: String, time: Date)] = []

    // MARK: - Public API

    /// Returns the current fused state. O(1) — just returns the cached struct.
    func snapshot() -> WorkState {
        return currentState
    }

    /// Ingest an observation event from ContinuousPerceptionDaemon.
    func ingest(_ event: ObservationEvent) {
        let now = event.timestamp

        // Prune old entries from rolling windows
        pruneWindow(before: now.addingTimeInterval(-windowDuration))

        switch event {
        case .userAction(let action):
            lastUserActionTime = now
            if let app = event.appName, app != currentApp {
                switchApp(to: app, at: now)
            }
            // Update window title from screen context if available
            if !action.elementTitle.isEmpty {
                currentWindowTitle = action.elementTitle
            }

        case .screenSample(let sample):
            if sample.appName != currentApp {
                switchApp(to: sample.appName, at: now)
            }
            // Use first visible text as a rough window title
            if let title = sample.visibleTextPreview.first, !title.isEmpty {
                currentWindowTitle = String(title.prefix(100))
            }

        case .clipboardFlow:
            recentClipboardTimes.append(now)
            // Snapshot clipboard text (first 100 chars) for enrichment suggestions
            if let text = NSPasteboard.general.string(forType: .string) {
                lastClipboardPreview = String(text.prefix(100))
            }

        case .fileEvent(let fileEvent):
            recentFileTimes.append(now)
            if !fileEvent.fileExtension.isEmpty {
                recentFileExtensionLog.append((ext: fileEvent.fileExtension, time: now))
            }

        case .systemEvent(let sysEvent):
            switch sysEvent.kind {
            case .appLaunched(let name):
                switchApp(to: name, at: now)
            case .screenLocked:
                lastActivityType = .idle
            case .screenUnlocked:
                lastUserActionTime = now
            case .focusModeChanged(let mode):
                cachedFocusMode = FocusMode(modeIdentifier: mode)
            default:
                break
            }
        }

        // Rebuild cached state
        rebuildState(at: now)
    }

    // MARK: - App Switching

    private func switchApp(to app: String, at time: Date) {
        guard app != currentApp else { return }
        appSwitchLog.append((app: app, time: time))
        currentApp = app
        currentWindowTitle = ""

        let newActivity = classifyActivity(app: app)
        if newActivity != lastActivityType {
            lastActivityType = newActivity
            activityStartTime = time
        }
    }

    // MARK: - Activity Classification

    private static let appCategories: [String: WorkState.ActivityType] = {
        var map: [String: WorkState.ActivityType] = [:]
        let coding: [String] = ["Xcode", "Terminal", "iTerm2", "Visual Studio Code", "Code", "Sublime Text", "Cursor", "Warp", "Nova", "BBEdit"]
        let writing: [String] = ["Pages", "Microsoft Word", "Word", "Notes", "TextEdit", "Notion", "Bear", "Ulysses", "Obsidian", "Typora"]
        let browsing: [String] = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]
        let communicating: [String] = ["Mail", "Slack", "Messages", "WeChat", "Telegram", "Discord", "Zoom", "Microsoft Teams", "Teams", "FaceTime"]
        let designing: [String] = ["Figma", "Sketch", "Adobe Photoshop", "Illustrator", "Pixelmator Pro", "Affinity Designer"]
        let presenting: [String] = ["Keynote", "Microsoft PowerPoint", "PowerPoint"]
        let reading: [String] = ["Preview", "Kindle", "Books", "Skim", "PDF Expert", "Zotero"]

        for app in coding { map[app] = .coding }
        for app in writing { map[app] = .writing }
        for app in browsing { map[app] = .browsing }
        for app in communicating { map[app] = .communicating }
        for app in designing { map[app] = .designing }
        for app in presenting { map[app] = .presenting }
        for app in reading { map[app] = .reading }
        return map
    }()

    private func classifyActivity(app: String) -> WorkState.ActivityType {
        return Self.appCategories[app] ?? .unknown
    }

    // MARK: - Window Pruning

    private func pruneWindow(before cutoff: Date) {
        recentClipboardTimes.removeAll { $0 < cutoff }
        recentFileTimes.removeAll { $0 < cutoff }
        recentFileExtensionLog.removeAll { $0.time < cutoff }
        appSwitchLog.removeAll { $0.time < cutoff }
    }

    // MARK: - State Rebuild

    private func rebuildState(at now: Date) {
        // Determine activity type (idle override)
        let activity: WorkState.ActivityType
        if now.timeIntervalSince(lastUserActionTime) > idleThreshold {
            activity = .idle
        } else {
            activity = lastActivityType
        }

        // Compute app dwell times from switch log
        let dwellMap = computeDwellTimes(at: now)
        let sortedDwells = dwellMap
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { WorkState.AppDwell(name: $0.key, seconds: Int($0.value)) }

        currentState = WorkState(
            currentApp: currentApp,
            windowTitle: currentWindowTitle,
            activityType: activity,
            activityStartTime: activity != lastActivityType ? now : activityStartTime,
            recentApps: sortedDwells,
            recentClipboardFlows: recentClipboardTimes.count,
            recentFileEvents: recentFileTimes.count,
            lastUserActionTime: lastUserActionTime,
            focusMode: cachedFocusMode,
            timestamp: now,
            lastClipboardPreview: lastClipboardPreview,
            recentFileExtensions: recentFileExtensionLog.map(\.ext)
        )
    }

    /// Compute dwell time per app from the switch log.
    private func computeDwellTimes(at now: Date) -> [String: TimeInterval] {
        var dwells: [String: TimeInterval] = [:]
        guard !appSwitchLog.isEmpty else { return dwells }

        for i in 0..<appSwitchLog.count {
            let entry = appSwitchLog[i]
            let endTime = (i + 1 < appSwitchLog.count) ? appSwitchLog[i + 1].time : now
            dwells[entry.app, default: 0] += endTime.timeIntervalSince(entry.time)
        }
        return dwells
    }
}
