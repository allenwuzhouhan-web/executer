import Foundation

// MARK: - ObservationEvent

/// Unified event type for the always-on observation pipeline.
/// Every observation source (AppObserver, FileMonitor, ClipboardObserver,
/// ScreenSampler, SystemEventBus) emits events as this single type,
/// enabling a unified AsyncStream with guaranteed ordering.
enum ObservationEvent: Sendable {
    case userAction(UserAction)
    case fileEvent(FileObservationEvent)
    case clipboardFlow(ClipboardObservationEvent)
    case screenSample(ScreenSampleEvent)
    case systemEvent(SystemObservationEvent)
    case oeAppEvent(OEAppEvent)
    case oeURLEvent(OEURLEvent)
    case oeActivityEvent(OEActivityEvent)
    case oeTransitionEvent(OETransitionEvent)
    case oeFileEvent(OEFileEvent)

    /// Timestamp of the event, regardless of source.
    var timestamp: Date {
        switch self {
        case .userAction(let a): return a.timestamp
        case .fileEvent(let e): return e.timestamp
        case .clipboardFlow(let f): return f.timestamp
        case .screenSample(let s): return s.timestamp
        case .systemEvent(let e): return e.timestamp
        case .oeAppEvent(let e): return e.timestamp
        case .oeURLEvent(let e): return e.timestamp
        case .oeActivityEvent(let e): return e.timestamp
        case .oeTransitionEvent(let e): return e.timestamp
        case .oeFileEvent(let e): return e.timestamp
        }
    }

    /// The app associated with the event (if any).
    var appName: String? {
        switch self {
        case .userAction(let a): return a.appName
        case .fileEvent(let e): return e.appName
        case .clipboardFlow(let f): return f.sourceApp
        case .screenSample(let s): return s.appName
        case .systemEvent(let e):
            switch e.kind {
            case .appLaunched(let name), .appQuit(let name): return name
            default: return nil
            }
        case .oeAppEvent(let e): return e.appName
        case .oeURLEvent, .oeActivityEvent, .oeFileEvent: return nil
        case .oeTransitionEvent(let e): return e.toApp
        }
    }

    /// Source identifier for logging and throttling.
    var source: EventSource {
        switch self {
        case .userAction: return .accessibility
        case .fileEvent: return .fileSystem
        case .clipboardFlow: return .clipboard
        case .screenSample: return .screenSampler
        case .systemEvent: return .system
        case .oeAppEvent, .oeURLEvent, .oeActivityEvent, .oeTransitionEvent, .oeFileEvent:
            return .observationEngine
        }
    }

    enum EventSource: String, Sendable {
        case accessibility
        case fileSystem
        case clipboard
        case screenSampler
        case system
        case observationEngine
    }
}

// MARK: - File Observation Event (Sendable wrapper)

/// Sendable version of FileMonitor.FileEvent for the observation pipeline.
struct FileObservationEvent: Sendable {
    let directory: String
    let fileExtension: String
    let eventType: EventType
    let appName: String
    let timestamp: Date

    enum EventType: String, Sendable {
        case created, modified, deleted, renamed
    }

    /// Convert from FileMonitor.FileEvent
    init(from event: FileMonitor.FileEvent) {
        self.directory = event.directory
        self.fileExtension = event.fileExtension
        self.eventType = EventType(rawValue: event.eventType.rawValue) ?? .modified
        self.appName = event.appName
        self.timestamp = event.timestamp
    }
}

// MARK: - Clipboard Observation Event (Sendable wrapper)

/// Sendable version of ClipboardObserver.ClipboardFlow for the observation pipeline.
struct ClipboardObservationEvent: Sendable {
    let sourceApp: String
    let destinationApp: String
    let contentType: ContentType
    let contentLength: Int
    let timestamp: Date

    enum ContentType: String, Sendable {
        case text, image, url, file, other
    }

    /// Convert from ClipboardObserver.ClipboardFlow
    init(from flow: ClipboardObserver.ClipboardFlow) {
        self.sourceApp = flow.sourceApp
        self.destinationApp = flow.destinationApp
        self.contentType = ContentType(rawValue: flow.contentType.rawValue) ?? .other
        self.contentLength = flow.contentLength
        self.timestamp = flow.timestamp
    }
}

// MARK: - Screen Sample Event

/// Captures a periodic screen sample — visible text from the frontmost app.
struct ScreenSampleEvent: Sendable {
    let appName: String
    let pid: Int32
    let visibleTextPreview: [String]  // First N text items (never stored raw)
    let elementCount: Int
    let timestamp: Date
    let screenHash: UInt64?           // dHash for pixel-level change detection
}

// MARK: - System Observation Event (Sendable wrapper)

/// Sendable version of SystemEventBus events for the observation pipeline.
struct SystemObservationEvent: Sendable {
    let kind: Kind
    let timestamp: Date

    enum Kind: Sendable {
        case appLaunched(name: String)
        case appQuit(name: String)
        case screenLocked
        case screenUnlocked
        case displayCountChanged(oldCount: Int, newCount: Int)
        case wifiChanged(newNetwork: String?)
        case powerSourceChanged(isAC: Bool)
        case batteryLevel(percent: Int)
        case focusModeChanged(mode: String)
    }
}
