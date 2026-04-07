import Foundation

/// Continuous background monitoring of email, calendar, news, and file changes.
/// Extracts normalized RadarSignals for downstream consumption by IntentEngine and AdaptiveNotifier.
actor InformationRadar {
    static let shared = InformationRadar()

    private var isRunning = false
    private var signals: [RadarSignal] = []
    private let maxSignals = 200

    // Scan cooldowns per source
    private var lastScanTime: [String: Date] = [:]
    private let emailInterval: TimeInterval = 900       // 15 min
    private let calendarInterval: TimeInterval = 900    // 15 min
    private let newsInterval: TimeInterval = 3600       // 1 hour
    private let reminderInterval: TimeInterval = 900    // 15 min

    private var scanTask: Task<Void, Never>?

    private static var storageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("radar_signals.json")
    }

    init() {
        signals = Self.loadFromDisk()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[InformationRadar] Started")

        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runScanCycle()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // Check every 60s
            }
        }
    }

    func stop() {
        isRunning = false
        scanTask?.cancel()
        scanTask = nil
        print("[InformationRadar] Stopped")
    }

    // MARK: - Scan Cycle

    private func runScanCycle() async {
        async let emailSignals = scanEmail()
        async let calendarSignals = scanCalendar()
        async let reminderSignals = scanReminders()
        async let newsSignals = scanNews()

        let allNew = await emailSignals + calendarSignals + reminderSignals + newsSignals

        if !allNew.isEmpty {
            for signal in allNew {
                signals.append(signal)
                // Notify ProjectMindMap if signal has a project association
                if let projectId = signal.relevantProjectId {
                    await ProjectMindMap.shared.handleRadarSignal(
                        projectId: projectId,
                        signalTitle: signal.title,
                        urgency: signal.urgency
                    )
                }
            }
            // Trim to max
            if signals.count > maxSignals {
                signals = Array(signals.suffix(maxSignals))
            }
            save()
            print("[InformationRadar] Emitted \(allNew.count) new signals (total: \(signals.count))")
        }
    }

    // MARK: - Source Scanners

    private func scanEmail() async -> [RadarSignal] {
        guard shouldScan("email", interval: emailInterval) else { return [] }
        markScanned("email")

        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: "search_mail",
                arguments: "{\"query\": \"is:unread\", \"limit\": 10}"
            )

            var signals: [RadarSignal] = []
            // Parse email results — each unread email becomes a signal
            let lines = result.components(separatedBy: "\n")
            for line in lines where line.contains("Subject:") || line.contains("From:") {
                let subject = line.replacingOccurrences(of: "Subject: ", with: "")
                let urgency: Double = line.lowercased().contains("urgent") ? 0.8 : 0.4
                let type: RadarSignal.SignalType = line.lowercased().contains("deadline") ? .deadlineChange : .newEmail
                signals.append(RadarSignal(
                    source: .email,
                    type: type,
                    title: String(subject.prefix(120)),
                    body: String(line.prefix(300)),
                    urgency: urgency
                ))
            }
            return signals
        } catch {
            print("[InformationRadar] Email scan failed: \(error)")
            return []
        }
    }

    private func scanCalendar() async -> [RadarSignal] {
        guard shouldScan("calendar", interval: calendarInterval) else { return [] }
        markScanned("calendar")

        do {
            let formatter = ISO8601DateFormatter()
            let now = formatter.string(from: Date())
            let tomorrow = formatter.string(from: Date().addingTimeInterval(86400))
            let result = try await ToolRegistry.shared.execute(
                toolName: "query_calendar_events",
                arguments: "{\"start_date\": \"\(now)\", \"end_date\": \"\(tomorrow)\"}"
            )

            var signals: [RadarSignal] = []
            let lines = result.components(separatedBy: "\n")
            for line in lines where !line.isEmpty && line.count > 5 {
                let hoursUntil = 24.0 // Simplified — real impl would parse the time
                let urgency = hoursUntil < 2 ? 0.8 : (hoursUntil < 6 ? 0.5 : 0.3)
                signals.append(RadarSignal(
                    source: .calendar,
                    type: .eventReminder,
                    title: String(line.prefix(120)),
                    body: line,
                    urgency: urgency
                ))
            }
            return signals
        } catch {
            print("[InformationRadar] Calendar scan failed: \(error)")
            return []
        }
    }

    private func scanReminders() async -> [RadarSignal] {
        guard shouldScan("reminder", interval: reminderInterval) else { return [] }
        markScanned("reminder")

        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: "query_reminders",
                arguments: "{\"show_completed\": false}"
            )

            var signals: [RadarSignal] = []
            let lines = result.components(separatedBy: "\n")
            for line in lines where !line.isEmpty && line.count > 3 {
                signals.append(RadarSignal(
                    source: .reminder,
                    type: .newTask,
                    title: String(line.prefix(120)),
                    body: line,
                    urgency: 0.4
                ))
            }
            return signals
        } catch {
            print("[InformationRadar] Reminder scan failed: \(error)")
            return []
        }
    }

    private func scanNews() async -> [RadarSignal] {
        guard shouldScan("news", interval: newsInterval) else { return [] }
        markScanned("news")

        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: "fetch_news",
                arguments: "{\"category\": \"technology\", \"limit\": 5}"
            )

            var signals: [RadarSignal] = []
            let lines = result.components(separatedBy: "\n")
            for line in lines where !line.isEmpty && line.count > 10 {
                signals.append(RadarSignal(
                    source: .news,
                    type: .newsUpdate,
                    title: String(line.prefix(120)),
                    body: line,
                    urgency: 0.2
                ))
            }
            return signals
        } catch {
            print("[InformationRadar] News scan failed: \(error)")
            return []
        }
    }

    /// Called by FileMonitor integration — converts file events into radar signals.
    func handleFileEvent(directory: String, fileExtension: String, eventType: String) {
        let signal = RadarSignal(
            source: .file,
            type: .fileCreated,
            title: "New \(fileExtension) file in \(directory)",
            body: "A .\(fileExtension) file was \(eventType) in \(directory)",
            urgency: 0.2
        )
        signals.append(signal)
        if signals.count > maxSignals {
            signals = Array(signals.suffix(maxSignals))
        }
    }

    // MARK: - Queries

    func recentSignals(limit: Int = 50) -> [RadarSignal] {
        Array(signals.suffix(limit))
    }

    func signalsSince(_ date: Date) -> [RadarSignal] {
        signals.filter { $0.timestamp > date }
    }

    func urgentSignals(threshold: Double = 0.6) -> [RadarSignal] {
        signals.filter { $0.urgency >= threshold }
    }

    func signalsBySource(_ source: RadarSignal.SignalSource) -> [RadarSignal] {
        signals.filter { $0.source == source }
    }

    // MARK: - Throttle Helpers

    private func shouldScan(_ source: String, interval: TimeInterval) -> Bool {
        guard let last = lastScanTime[source] else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private func markScanned(_ source: String) {
        lastScanTime[source] = Date()
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(signals) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private static func loadFromDisk() -> [RadarSignal] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RadarSignal].self, from: data)) ?? []
    }
}
