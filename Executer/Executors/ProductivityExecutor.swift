import Foundation
import Cocoa
import EventKit
import UserNotifications

struct CreateReminderTool: ToolDefinition {
    let name = "create_reminder"
    let description = "Create a new reminder in the Reminders app"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The reminder title"),
            "notes": JSONSchema.string(description: "Optional notes for the reminder"),
            "due_date": JSONSchema.string(description: "Optional due date in ISO 8601 format (e.g., 2024-12-25T10:00:00)")
        ], required: ["title"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let notes = optionalString("notes", from: args)
        let dueDateStr = optionalString("due_date", from: args)

        let store = EKEventStore()
        try await store.requestFullAccessToReminders()

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()

        if let dateStr = dueDateStr {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateStr) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: date
                )
            }
        }

        try store.save(reminder, commit: true)
        return "Created reminder: \(title)"
    }
}

struct CreateCalendarEventTool: ToolDefinition {
    let name = "create_calendar_event"
    let description = "Create a new calendar event"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The event title"),
            "start_date": JSONSchema.string(description: "Start date in ISO 8601 format"),
            "end_date": JSONSchema.string(description: "End date in ISO 8601 format"),
            "location": JSONSchema.string(description: "Optional event location"),
            "notes": JSONSchema.string(description: "Optional event notes")
        ], required: ["title", "start_date", "end_date"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let startStr = try requiredString("start_date", from: args)
        let endStr = try requiredString("end_date", from: args)

        let store = EKEventStore()
        try await store.requestFullAccessToEvents()

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = optionalString("notes", from: args)
        event.location = optionalString("location", from: args)
        event.calendar = store.defaultCalendarForNewEvents

        let formatter = ISO8601DateFormatter()
        event.startDate = formatter.date(from: startStr) ?? Date()
        event.endDate = formatter.date(from: endStr) ?? Date().addingTimeInterval(3600)

        try store.save(event, span: .thisEvent)
        return "Created event: \(title)"
    }
}

struct CreateNoteTool: ToolDefinition {
    let name = "create_note"
    let description = "Create a new note in the Notes app"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The note title"),
            "body": JSONSchema.string(description: "The note body text")
        ], required: ["title", "body"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let body = try requiredString("body", from: args)
        let script = """
        tell application "Notes"
            make new note at folder "Notes" with properties {name:"\(title)", body:"\(body)"}
        end tell
        """
        try AppleScriptRunner.runThrowing(script)
        return "Created note: \(title)"
    }
}

struct SetTimerTool: ToolDefinition {
    let name = "set_timer"
    let description = "Set a timer that sends a notification when it expires"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "duration_seconds": JSONSchema.integer(description: "Duration in seconds"),
            "minutes": JSONSchema.integer(description: "Duration in minutes (ignored if duration_seconds is set)", minimum: 1, maximum: 1440),
            "label": JSONSchema.string(description: "Optional label for the timer")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let label = optionalString("label", from: args) ?? "Timer"

        // Accept either duration_seconds or minutes
        let totalSeconds: Int
        if let secs = optionalInt("duration_seconds", from: args), secs > 0 {
            totalSeconds = secs
        } else {
            totalSeconds = (optionalInt("minutes", from: args) ?? 5) * 60
        }
        let minutes = max(1, totalSeconds / 60)

        // Schedule a notification
        let content = UNMutableNotificationContent()
        content.title = "Timer: \(label)"
        content.body = "\(minutes) minute timer is up!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(totalSeconds),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "timer-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)

        // Also schedule a direct sound playback as backup (survives Focus/DND)
        let timerInterval = TimeInterval(totalSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + timerInterval) {
            AlarmPlayer.play(label: label, time: "\(minutes)m timer")
        }

        return "Timer set for \(minutes) minutes (\(label))."
    }
}

struct SetAlarmTool: ToolDefinition {
    let name = "set_alarm"
    let description = "Set an alarm at a specific time. Plays a sound and shows a notification when the time arrives. Works like a clock alarm."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "time": JSONSchema.string(description: "Time in HH:MM format (24-hour) e.g. '18:50' for 6:50 PM, or '07:00' for 7 AM"),
            "label": JSONSchema.string(description: "Optional label for the alarm"),
        ], required: ["time"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let timeStr = try requiredString("time", from: args)
        let label = optionalString("label", from: args) ?? "Alarm"

        // Parse HH:MM
        let parts = timeStr.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              hour >= 0, hour < 24, minute >= 0, minute < 60 else {
            return "Invalid time format. Use HH:MM (24-hour), e.g. '18:50' or '07:00'."
        }

        // Calculate time interval until the target time
        let calendar = Calendar.current
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        targetComponents.hour = hour
        targetComponents.minute = minute
        targetComponents.second = 0

        guard var targetDate = calendar.date(from: targetComponents) else {
            return "Failed to calculate alarm time."
        }

        // If the target time is in the past today, set for tomorrow
        if targetDate <= Date() {
            targetDate = calendar.date(byAdding: .day, value: 1, to: targetDate)!
        }

        let interval = targetDate.timeIntervalSince(Date())

        // Schedule notification with alarm sound
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(label)"
        content.body = "Alarm: \(timeStr)"
        content.sound = AlarmSoundPreference.notificationSound

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "alarm-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)

        // Also schedule a direct sound playback as backup (survives Focus/DND)
        let alarmInterval = interval
        DispatchQueue.main.asyncAfter(deadline: .now() + alarmInterval) {
            AlarmPlayer.play(label: label, time: timeStr)
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let displayTime = formatter.string(from: targetDate)
        let minutesUntil = Int(interval / 60)
        return "Alarm set for \(displayTime) (\(label)). That's in \(minutesUntil) minutes."
    }
}

/// Plays alarm sound directly via NSSound — not dependent on notification delivery
enum AlarmPlayer {
    private static var playCount = 0
    private static var timer: Timer?

    static func play(label: String, time: String) {
        let soundName = UserDefaults.standard.string(forKey: "alarm_sound") ?? "Glass"
        playCount = 0

        // Play the sound 5 times with 2-second gaps so the user actually notices
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { t in
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            } else {
                NSSound.beep()
            }
            playCount += 1
            if playCount >= 5 {
                t.invalidate()
                timer = nil
            }
        }
        timer?.fire() // play immediately too
    }
}

// MARK: - Step 3: Calendar & Reminders Query Tools

struct QueryCalendarEventsTool: ToolDefinition {
    let name = "query_calendar_events"
    let description = "Query upcoming calendar events within a date range"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "start_date": JSONSchema.string(description: "Start of range in ISO 8601 format (default: now)"),
            "end_date": JSONSchema.string(description: "End of range in ISO 8601 format (default: 24 hours from now)"),
            "limit": JSONSchema.integer(description: "Maximum number of events to return (default 20)", minimum: 1, maximum: 100)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let limit = optionalInt("limit", from: args) ?? 20

        let formatter = ISO8601DateFormatter()
        let startDate = optionalString("start_date", from: args).flatMap { formatter.date(from: $0) } ?? Date()
        let endDate = optionalString("end_date", from: args).flatMap { formatter.date(from: $0) } ?? Date().addingTimeInterval(24 * 3600)

        let store = EKEventStore()
        try await store.requestFullAccessToEvents()

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        if events.isEmpty {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d"
            return "No events found between \(dateFormatter.string(from: startDate)) and \(dateFormatter.string(from: endDate))."
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "h:mm a"

        let lines = events.map { event -> String in
            let start = dateFormatter.string(from: event.startDate)
            let end = dateFormatter.string(from: event.endDate)
            var line = "- \(start)–\(end): \(event.title ?? "Untitled")"
            if let location = event.location, !location.isEmpty {
                line += " (\(location))"
            }
            return line
        }

        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "EEEE, MMM d"
        return "Events (\(headerFormatter.string(from: startDate))):\n\(lines.joined(separator: "\n"))"
    }
}

struct QueryRemindersTool: ToolDefinition {
    let name = "query_reminders"
    let description = "Query reminders from the Reminders app"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "show_completed": JSONSchema.boolean(description: "Whether to include completed reminders (default false)"),
            "limit": JSONSchema.integer(description: "Maximum number of reminders to return (default 20)", minimum: 1, maximum: 100)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let showCompleted = optionalBool("show_completed", from: args) ?? false
        let limit = optionalInt("limit", from: args) ?? 20

        let store = EKEventStore()
        try await store.requestFullAccessToReminders()

        let predicate: NSPredicate
        if showCompleted {
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        }

        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }

        let limited = Array(reminders.prefix(limit))
        if limited.isEmpty {
            return showCompleted ? "No completed reminders found." : "No pending reminders."
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"

        let lines = limited.map { reminder -> String in
            let check = reminder.isCompleted ? "[x]" : "[ ]"
            var line = "\(check) \(reminder.title ?? "Untitled")"
            if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
                line += " (due \(dateFormatter.string(from: date)))"
            }
            return line
        }

        let status = showCompleted ? "completed" : "pending"
        return "Reminders (\(limited.count) \(status)):\n\(lines.joined(separator: "\n"))"
    }
}

struct OpenSystemPreferencesTool: ToolDefinition {
    let name = "open_system_preferences_pane"
    let description = "Open a specific pane in System Settings"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "pane": JSONSchema.enumString(description: "Which settings pane to open", values: [
                "general", "appearance", "accessibility", "control-center",
                "desktop", "dock", "displays", "wallpaper",
                "battery", "lock-screen", "users",
                "passwords", "network", "bluetooth", "sound",
                "notifications", "focus", "screen-time",
                "privacy", "keyboard", "trackpad", "mouse",
                "printers", "date-time", "language", "sharing"
            ])
        ], required: ["pane"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pane = try requiredString("pane", from: args)

        // macOS Ventura+ uses x-apple.systempreferences URLs
        let url: String
        switch pane.lowercased() {
        case "general": url = "x-apple.systempreferences:com.apple.SystemPreferences"
        case "appearance": url = "x-apple.systempreferences:com.apple.Appearance-Settings.extension"
        case "accessibility": url = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
        case "network": url = "x-apple.systempreferences:com.apple.Network-Settings.extension"
        case "bluetooth": url = "x-apple.systempreferences:com.apple.BluetoothSettings"
        case "sound": url = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case "displays": url = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        case "battery": url = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        case "keyboard": url = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case "trackpad": url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case "privacy": url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        case "notifications": url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case "focus": url = "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case "wallpaper": url = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
        case "dock": url = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        default: url = "x-apple.systempreferences:"
        }

        NSWorkspace.shared.open(URL(string: url)!)
        return "Opened \(pane) settings."
    }
}
