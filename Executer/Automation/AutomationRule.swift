import Foundation

// MARK: - Automation Rule

struct AutomationRule: Codable, Identifiable {
    let id: String
    let naturalLanguage: String
    let trigger: RuleTrigger
    let actions: [RuleAction]
    var enabled: Bool
    let createdAt: Date
    var lastFiredAt: Date?
    var cooldownSeconds: Int

    init(naturalLanguage: String, trigger: RuleTrigger, actions: [RuleAction], cooldownSeconds: Int = 60) {
        self.id = UUID().uuidString
        self.naturalLanguage = naturalLanguage
        self.trigger = trigger
        self.actions = actions
        self.enabled = true
        self.createdAt = Date()
        self.lastFiredAt = nil
        self.cooldownSeconds = cooldownSeconds
    }
}

// MARK: - Triggers

enum RuleTrigger: Codable, Equatable {
    case displayConnected
    case displayDisconnected
    case wifiConnected(networkName: String?)
    case wifiDisconnected
    case timeOfDay(hour: Int, minute: Int)
    case appLaunched(appName: String)
    case appQuit(appName: String)
    case batteryLow(threshold: Int)
    case powerConnected
    case powerDisconnected
    case screenLocked
    case screenUnlocked
    case focusChanged(mode: String?)

    var displayDescription: String {
        switch self {
        case .displayConnected: return "Display connected"
        case .displayDisconnected: return "Display disconnected"
        case .wifiConnected(let name): return "Wi-Fi connected\(name.map { " to \($0)" } ?? "")"
        case .wifiDisconnected: return "Wi-Fi disconnected"
        case .timeOfDay(let h, let m): return String(format: "Every day at %d:%02d", h, m)
        case .appLaunched(let app): return "\(app) launched"
        case .appQuit(let app): return "\(app) quit"
        case .batteryLow(let t): return "Battery below \(t)%"
        case .powerConnected: return "Charger connected"
        case .powerDisconnected: return "Charger disconnected"
        case .screenLocked: return "Screen locked"
        case .screenUnlocked: return "Screen unlocked"
        case .focusChanged(let mode): return "Focus changed\(mode.map { " to \($0)" } ?? "")"
        }
    }
}

// MARK: - Actions

enum RuleAction: Codable {
    case launchApp(name: String)
    case quitApp(name: String)
    case shellCommand(command: String)
    case setVolume(level: Int)
    case toggleDarkMode
    case showNotification(title: String, body: String)
    case naturalLanguage(command: String)
    case startOvernightAgent

    var displayDescription: String {
        switch self {
        case .launchApp(let name): return "Open \(name)"
        case .quitApp(let name): return "Quit \(name)"
        case .shellCommand(let cmd): return "Run: \(cmd.prefix(40))"
        case .setVolume(let level): return "Set volume to \(level)%"
        case .toggleDarkMode: return "Toggle dark mode"
        case .showNotification(let title, _): return "Notify: \(title)"
        case .naturalLanguage(let cmd): return cmd.prefix(50).description
        case .startOvernightAgent: return "Start overnight agent"
        }
    }
}

// MARK: - System Event (for matching)

enum SystemEvent {
    case displayCountChanged(oldCount: Int, newCount: Int)
    case wifiChanged(newNetwork: String?)
    case timeReached(hour: Int, minute: Int)
    case appLaunched(name: String)
    case appQuit(name: String)
    case batteryLevel(percent: Int)
    case powerSourceChanged(isAC: Bool)
    case screenLocked
    case screenUnlocked
    case focusChanged(mode: String?)
}
