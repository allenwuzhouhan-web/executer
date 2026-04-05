import Foundation
import Cocoa

/// Monitors system events and fires matching automation rules.
class SystemEventBus {
    static let shared = SystemEventBus()
    private init() {}

    private var displayCount: Int = 0
    private var currentWifi: String? = nil
    private var isOnACPower: Bool = true
    private var lastBatteryPercent: Int = 100
    private var batteryAlertFired: Set<String> = [] // rule IDs that already fired for current battery session
    private var pollTimer: Timer?
    private var timeTimers: [Timer] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var lockObservers: [NSObjectProtocol] = []

    func start() {
        print("[EventBus] Starting system event monitoring")

        // Remove existing observers to prevent duplicates on repeated start() calls
        if !workspaceObservers.isEmpty {
            for obs in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            workspaceObservers.removeAll()
        }

        // Capture initial state
        displayCount = NSScreen.screens.count
        currentWifi = getCurrentWifi()
        (isOnACPower, lastBatteryPercent) = getPowerState()

        // Display changes (event-driven)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }

        // App launch/quit (event-driven)
        let launchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let name = app.localizedName {
                self?.handleEvent(.appLaunched(name: name))
            }
        }
        workspaceObservers.append(launchObs)

        let quitObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let name = app.localizedName {
                self?.handleEvent(.appQuit(name: name))
            }
        }
        workspaceObservers.append(quitObs)

        // Screen lock/unlock (event-driven via distributed notifications)
        let lockObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEvent(.screenLocked)
        }
        lockObservers.append(lockObs)

        let unlockObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEvent(.screenUnlocked)
        }
        lockObservers.append(unlockObs)

        // Polling timer for Wi-Fi, battery, power (every 30s)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pollSystemState()
        }

        // Schedule time-based triggers
        scheduleTimeBasedTriggers()
    }

    /// Called when rules are added/removed to reschedule time triggers.
    func rulesDidChange() {
        scheduleTimeBasedTriggers()
    }

    // MARK: - Event Handling

    private func handleDisplayChange() {
        let newCount = NSScreen.screens.count
        let oldCount = displayCount
        guard newCount != oldCount else { return }
        displayCount = newCount
        print("[EventBus] Display count changed: \(oldCount) -> \(newCount)")
        handleEvent(.displayCountChanged(oldCount: oldCount, newCount: newCount))
    }

    private func pollSystemState() {
        // Wi-Fi
        let newWifi = getCurrentWifi()
        if newWifi != currentWifi {
            let oldWifi = currentWifi
            currentWifi = newWifi
            print("[EventBus] Wi-Fi changed: \(oldWifi ?? "none") -> \(newWifi ?? "none")")
            handleEvent(.wifiChanged(newNetwork: newWifi))
        }

        // Power & Battery
        let (newIsAC, newBattery) = getPowerState()
        if newIsAC != isOnACPower {
            isOnACPower = newIsAC
            print("[EventBus] Power source changed: \(newIsAC ? "AC" : "Battery")")
            handleEvent(.powerSourceChanged(isAC: newIsAC))
            if newIsAC {
                batteryAlertFired.removeAll() // Reset battery alerts when plugged in
            }
        }
        if newBattery != lastBatteryPercent {
            lastBatteryPercent = newBattery
            handleEvent(.batteryLevel(percent: newBattery))
        }
    }

    private func handleEvent(_ event: SystemEvent) {
        let matching = AutomationRuleManager.shared.matchingRules(for: event)
        for rule in matching {
            // Skip battery alerts that already fired this session
            if case .batteryLow = rule.trigger {
                if batteryAlertFired.contains(rule.id) { continue }
                batteryAlertFired.insert(rule.id)
            }

            print("[EventBus] Firing rule: \(rule.naturalLanguage)")
            AutomationRuleManager.shared.markFired(id: rule.id)
            executeActions(rule.actions)
        }
    }

    private func executeActions(_ actions: [RuleAction]) {
        for action in actions {
            Task {
                do {
                    switch action {
                    case .launchApp(let name):
                        let args = "{\"app_name\": \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                        _ = try await LaunchAppTool().execute(arguments: args)
                    case .quitApp(let name):
                        let args = "{\"app_name\": \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                        _ = try await QuitAppTool().execute(arguments: args)
                    case .shellCommand(let command):
                        _ = try ShellRunner.run(command, timeout: 30)
                    case .setVolume(let level):
                        _ = try await SetVolumeTool().execute(arguments: "{\"volume\": \(level)}")
                    case .toggleDarkMode:
                        _ = try await ToggleDarkModeTool().execute(arguments: "{}")
                    case .showNotification(let title, let body):
                        _ = try await ShowNotificationTool().execute(
                            arguments: "{\"title\": \"\(title)\", \"message\": \"\(body)\"}"
                        )
                    case .naturalLanguage(let command):
                        // Submit to the LLM via AppState
                        await MainActor.run {
                            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                                delegate.appState.showInputBar()
                                delegate.appState.submitCommand(command)
                            }
                        }
                    case .startOvernightAgent:
                        await OvernightAgent.shared.activate()
                    }
                    print("[EventBus] Action executed: \(action.displayDescription)")
                } catch {
                    print("[EventBus] Action failed: \(error)")
                }
            }
        }
    }

    // MARK: - Time-Based Triggers

    private func scheduleTimeBasedTriggers() {
        // Cancel existing time timers
        timeTimers.forEach { $0.invalidate() }
        timeTimers.removeAll()

        let rules = AutomationRuleManager.shared.rules.filter { rule in
            guard rule.enabled, case .timeOfDay = rule.trigger else { return false }
            return true
        }

        for rule in rules {
            guard case .timeOfDay(let hour, let minute) = rule.trigger else { continue }
            scheduleDaily(hour: hour, minute: minute)
        }
    }

    private func scheduleDaily(hour: Int, minute: Int) {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        guard let nextFire = calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) else {
            return
        }

        let interval = nextFire.timeIntervalSinceNow
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleEvent(.timeReached(hour: hour, minute: minute))
            // Reschedule for tomorrow
            self?.scheduleDaily(hour: hour, minute: minute)
        }
        timeTimers.append(timer)
        print("[EventBus] Scheduled time trigger for \(String(format: "%d:%02d", hour, minute))")
    }

    // MARK: - System State Queries

    private func getCurrentWifi() -> String? {
        guard let result = try? ShellRunner.run("networksetup -getairportnetwork en0 2>/dev/null", timeout: 5) else {
            return nil
        }
        if result.output.contains("Current Wi-Fi Network:") {
            return result.output.replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func getPowerState() -> (isAC: Bool, batteryPercent: Int) {
        guard let result = try? ShellRunner.run("pmset -g batt 2>/dev/null", timeout: 5) else {
            return (true, 100)
        }
        let output = result.output
        let isAC = output.contains("AC Power")
        var percent = 100
        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            percent = Int(String(output[range]).replacingOccurrences(of: "%", with: "")) ?? 100
        }
        return (isAC, percent)
    }
}
