import Foundation
import CoreGraphics

// MARK: - Observer 1: App Events

/// Emitted when the frontmost app changes. Records the PREVIOUS app's duration.
struct OEAppEvent: Codable, Sendable {
    let timestamp: Date
    let bundleId: String        // "com.apple.Safari"
    let appName: String         // "Safari"
    let windowTitle: String     // "ManageBac - Assignments"
    let duration: TimeInterval  // how long it was frontmost before switching
    let focusMode: String?      // current macOS Focus mode, if any
}

// MARK: - Observer 2: URL Events

/// Emitted when the user visits a URL in a browser.
/// Privacy: query parameters are stripped. Only domain + path stored.
struct OEURLEvent: Codable, Sendable {
    let timestamp: Date
    let domain: String          // "managebac.com"
    let path: String            // "/student/assignments"
    let pageTitle: String       // from window title
    let browserBundleId: String // "com.apple.Safari"
    let duration: TimeInterval  // time on this URL before navigating away
}

// MARK: - Observer 3: Activity Events

/// Emitted every 30 seconds with interaction intensity counts.
/// CRITICAL: never records WHICH keys — only counts. Privacy hard line.
struct OEActivityEvent: Codable, Sendable {
    let timestamp: Date
    let windowInterval: TimeInterval  // the time window (typically 30s)
    let keystrokes: Int
    let clicks: Int
    let scrollDistance: CGFloat
    let appBundleId: String
    let interactionMode: InteractionMode
}

// MARK: - Observer 4: Transition Events

/// Emitted on every app-to-app or URL-to-URL transition.
/// These are the MOST VALUABLE data for learning workflows.
struct OETransitionEvent: Codable, Sendable {
    let timestamp: Date
    let fromApp: String         // bundle ID
    let fromContext: String     // window title or domain
    let toApp: String           // bundle ID
    let toContext: String       // window title or domain
    let interactionMode: InteractionMode
    let focusMode: String?
    let hourOfDay: Int          // 0-23
    let dayOfWeek: Int          // 1-7 (Mon=1, Sun=7)
}

// MARK: - Observer 5: File Events

/// Emitted on file creation, modification, deletion, rename.
/// Privacy: only metadata (extension, directory), never content or full filename.
struct OEFileEvent: Codable, Sendable {
    let timestamp: Date
    let fileExtension: String   // "swift", "pptx", "pdf"
    let directory: String       // "Documents", "G8/Chemistry"
    let eventType: ObservedFileEventType
    let appBundleId: String?    // which app had it open
}

// MARK: - Unified Observation Wrapper

/// Wraps any observation event for storage in ObservationStore.
/// The event_data column stores the JSON-encoded inner event.
enum OEObservation: Sendable {
    case app(OEAppEvent)
    case url(OEURLEvent)
    case activity(OEActivityEvent)
    case transition(OETransitionEvent)
    case file(OEFileEvent)

    var observerType: ObserverType {
        switch self {
        case .app:        return .app
        case .url:        return .url
        case .activity:   return .activity
        case .transition: return .transition
        case .file:       return .file
        }
    }

    var timestamp: Date {
        switch self {
        case .app(let e):        return e.timestamp
        case .url(let e):        return e.timestamp
        case .activity(let e):   return e.timestamp
        case .transition(let e): return e.timestamp
        case .file(let e):       return e.timestamp
        }
    }

    var focusMode: String? {
        switch self {
        case .app(let e):        return e.focusMode
        case .transition(let e): return e.focusMode
        default:                 return nil
        }
    }

    /// Interaction weight per Principle 4.
    var interactionWeight: Double {
        switch self {
        case .app:               return 1.0  // app switch is always an active choice
        case .url:               return 1.0  // navigating to a URL is active
        case .activity(let e):   return e.interactionMode.observationWeight
        case .transition(let e): return e.interactionMode.observationWeight
        case .file:              return 1.0  // file operations are active
        }
    }

    /// JSON-encode the inner event for storage.
    func encodeEventData() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data: Data?
        switch self {
        case .app(let e):        data = try? encoder.encode(e)
        case .url(let e):        data = try? encoder.encode(e)
        case .activity(let e):   data = try? encoder.encode(e)
        case .transition(let e): data = try? encoder.encode(e)
        case .file(let e):       data = try? encoder.encode(e)
        }
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
