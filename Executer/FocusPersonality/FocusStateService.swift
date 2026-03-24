import Foundation
import Cocoa

enum FocusMode: Equatable, Codable {
    case none
    case work
    case reading
    case personalTime
    case mindfulness
    case reduceInterruptions
    case sleep
    case doNotDisturb
    case driving
    case custom(String)

    var displayName: String {
        switch self {
        case .none: return "None"
        case .work: return "Work"
        case .reading: return "Reading"
        case .personalTime: return "Personal"
        case .mindfulness: return "Mindfulness"
        case .reduceInterruptions: return "Reduce Interruptions"
        case .sleep: return "Sleep"
        case .doNotDisturb: return "Do Not Disturb"
        case .driving: return "Driving"
        case .custom(let name): return name
        }
    }

    init(modeIdentifier: String) {
        switch modeIdentifier {
        case "com.apple.focus.work": self = .work
        case "com.apple.focus.reading": self = .reading
        case "com.apple.focus.personal-time": self = .personalTime
        case "com.apple.focus.mindfulness": self = .mindfulness
        case "com.apple.focus.reduce-interruptions": self = .reduceInterruptions
        case "com.apple.sleep.sleep-mode": self = .sleep
        case "com.apple.donotdisturb.mode.default": self = .doNotDisturb
        case "com.apple.donotdisturb.mode.driving": self = .driving
        default:
            if modeIdentifier.isEmpty {
                self = .none
            } else {
                self = .custom(modeIdentifier)
            }
        }
    }

    // Codable conformance for the custom case
    enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "none": self = .none
        case "work": self = .work
        case "reading": self = .reading
        case "personalTime": self = .personalTime
        case "mindfulness": self = .mindfulness
        case "reduceInterruptions": self = .reduceInterruptions
        case "sleep": self = .sleep
        case "doNotDisturb": self = .doNotDisturb
        case "driving": self = .driving
        case "custom": self = .custom(try container.decode(String.self, forKey: .value))
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .custom(let name):
            try container.encode("custom", forKey: .type)
            try container.encode(name, forKey: .value)
        default:
            try container.encode(String(describing: self), forKey: .type)
        }
    }
}

class FocusStateService: ObservableObject {
    static let shared = FocusStateService()

    @Published var currentFocus: FocusMode = .none

    private var pollTimer: Timer?
    private var notificationObserver: Any?

    private let assertionsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/DoNotDisturb/DB/Assertions.json"
    }()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        print("[FocusState] Starting focus detection")

        // Get initial state immediately
        pollFocusState()

        // Primary: distributed notification
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.donotdisturbd.focus_configuration_events"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("[FocusState] Received focus change notification")
            // Small delay — the Assertions.json may not be updated yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.pollFocusState()
            }
        }

        // Fallback: poll every 30 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pollFocusState()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            notificationObserver = nil
        }
    }

    // MARK: - Detection

    private func pollFocusState() {
        // Try reading Assertions.json
        guard FileManager.default.fileExists(atPath: assertionsPath) else {
            updateFocus(.none)
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: assertionsPath))
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            // Navigate the JSON structure to find the active assertion
            if let storeRecords = parsed?["storeAssertionRecords"] as? [[String: Any]] {
                let activeModeId = findActiveModeId(in: storeRecords)
                let mode = FocusMode(modeIdentifier: activeModeId ?? "")
                updateFocus(mode)
                return
            }

            // Alternative structure: direct "data" array
            if let dataArray = parsed?["data"] as? [[String: Any]] {
                let activeModeId = findActiveModeId(in: dataArray)
                let mode = FocusMode(modeIdentifier: activeModeId ?? "")
                updateFocus(mode)
                return
            }

            updateFocus(.none)
        } catch {
            print("[FocusState] Failed to read Assertions.json: \(error.localizedDescription)")
            updateFocus(.none)
        }
    }

    private func findActiveModeId(in records: [[String: Any]]) -> String? {
        for record in records {
            // Look for assertionDetails containing mode identifier
            if let details = record["assertionDetails"] as? [String: Any],
               let modeId = details["assertionDetailIdentifierMode"] as? String {
                return modeId
            }

            // Alternative: nested assertionDetails array
            if let details = record["assertionDetails"] as? [[String: Any]] {
                for detail in details {
                    if let modeId = detail["assertionDetailIdentifierMode"] as? String {
                        return modeId
                    }
                }
            }

            // Try direct modeIdentifier field
            if let modeId = record["modeIdentifier"] as? String, !modeId.isEmpty {
                return modeId
            }

            // Try nested properties
            if let properties = record["properties"] as? [String: Any],
               let modeId = properties["modeIdentifier"] as? String {
                return modeId
            }
        }
        return nil
    }

    private func updateFocus(_ mode: FocusMode) {
        if currentFocus != mode {
            let old = currentFocus
            currentFocus = mode
            print("[FocusState] Changed: \(old.displayName) → \(mode.displayName)")
        }
    }

    deinit {
        stop()
    }
}
