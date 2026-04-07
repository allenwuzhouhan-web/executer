import Foundation
import Cocoa
import EventKit
import UserNotifications

// MARK: - Shared EventKit Store

/// Shared EKEventStore to avoid redundant permission prompts and improve performance.
private let sharedEventStore = EKEventStore()

private func ensureCalendarAccess() async throws {
    try await sharedEventStore.requestFullAccessToEvents()
}

private func ensureReminderAccess() async throws {
    try await sharedEventStore.requestFullAccessToReminders()
}

/// Find a calendar by name (case-insensitive partial match), or return nil.
private func findCalendar(named name: String, type: EKEntityType) -> EKCalendar? {
    let calendars = sharedEventStore.calendars(for: type)
    // Exact match first
    if let exact = calendars.first(where: { $0.title.lowercased() == name.lowercased() }) {
        return exact
    }
    // Partial match
    return calendars.first(where: { $0.title.lowercased().contains(name.lowercased()) })
}

/// Shared ISO 8601 formatter that also handles dates without time zone suffix.
private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = formatter.date(from: string) { return d }
    formatter.formatOptions = [.withInternetDateTime]
    if let d = formatter.date(from: string) { return d }
    // Try without timezone (assume local)
    formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    formatter.timeZone = .current
    if let d = formatter.date(from: string) { return d }
    // Try date-only
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    return formatter.date(from: string)
}

// MARK: - Calendar Tools

struct ListCalendarsTool: ToolDefinition {
    let name = "list_calendars"
    let description = "List all available calendars on this Mac, showing calendar name, type (local/iCloud/subscribed/birthday), and color"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        try await ensureCalendarAccess()
        let calendars = sharedEventStore.calendars(for: .event).sorted { $0.title < $1.title }
        if calendars.isEmpty { return "No calendars found." }

        let lines = calendars.map { cal -> String in
            let src = cal.source?.title ?? "Unknown"
            let defaultMarker = (cal == sharedEventStore.defaultCalendarForNewEvents) ? " (default)" : ""
            return "- \(cal.title) [\(src)]\(defaultMarker)"
        }
        return "Calendars (\(calendars.count)):\n\(lines.joined(separator: "\n"))"
    }
}

struct CreateCalendarEventTool: ToolDefinition {
    let name = "create_calendar_event"
    let description = "Create a new calendar event. Supports all-day events, alerts, location, URL, and choosing which calendar to add to."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The event title"),
            "start_date": JSONSchema.string(description: "Start date in ISO 8601 format (e.g., 2026-04-05T14:00:00)"),
            "end_date": JSONSchema.string(description: "End date in ISO 8601 format (e.g., 2026-04-05T15:00:00)"),
            "all_day": JSONSchema.boolean(description: "Whether this is an all-day event (default false)"),
            "location": JSONSchema.string(description: "Optional event location"),
            "notes": JSONSchema.string(description: "Optional event notes/description"),
            "url": JSONSchema.string(description: "Optional URL to attach to the event"),
            "calendar_name": JSONSchema.string(description: "Name of the calendar to add to (default: system default calendar). Use list_calendars to see available calendars."),
            "alert_minutes": JSONSchema.integer(description: "Minutes before the event to show an alert/reminder (e.g., 15 for 15 min before)", minimum: 0, maximum: 10080)
        ], required: ["title", "start_date", "end_date"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let startStr = try requiredString("start_date", from: args)
        let endStr = try requiredString("end_date", from: args)
        let allDay = optionalBool("all_day", from: args) ?? false

        try await ensureCalendarAccess()

        let event = EKEvent(eventStore: sharedEventStore)
        event.title = title
        event.notes = optionalString("notes", from: args)
        event.location = optionalString("location", from: args)
        event.isAllDay = allDay

        if let urlStr = optionalString("url", from: args), let url = URL(string: urlStr) {
            event.url = url
        }

        // Calendar selection
        if let calName = optionalString("calendar_name", from: args),
           let cal = findCalendar(named: calName, type: .event) {
            event.calendar = cal
        } else {
            event.calendar = sharedEventStore.defaultCalendarForNewEvents
        }

        // Parse dates
        event.startDate = parseISO8601(startStr) ?? Date()
        event.endDate = parseISO8601(endStr) ?? Date().addingTimeInterval(3600)

        // Alert
        if let alertMins = optionalInt("alert_minutes", from: args) {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMins * 60)))
        }

        try sharedEventStore.save(event, span: .thisEvent)

        let calName = event.calendar?.title ?? "default"
        let df = DateFormatter()
        df.dateFormat = allDay ? "EEEE, MMM d" : "MMM d, h:mm a"
        let startDisplay = df.string(from: event.startDate)
        return "Created event: \"\(title)\" on \(startDisplay) in calendar \"\(calName)\""
    }
}

struct QueryCalendarEventsTool: ToolDefinition {
    let name = "query_calendar_events"
    let description = "Query calendar events within a date range. Returns event details including title, time, location, calendar name, notes, and event ID (for updating/deleting)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "start_date": JSONSchema.string(description: "Start of range in ISO 8601 format (default: now)"),
            "end_date": JSONSchema.string(description: "End of range in ISO 8601 format (default: 24 hours from now)"),
            "calendar_name": JSONSchema.string(description: "Optional: only show events from this calendar"),
            "search_text": JSONSchema.string(description: "Optional: filter events whose title contains this text (case-insensitive)"),
            "limit": JSONSchema.integer(description: "Maximum number of events to return (default 25)", minimum: 1, maximum: 200)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let limit = optionalInt("limit", from: args) ?? 25
        let searchText = optionalString("search_text", from: args)?.lowercased()

        let startDate = optionalString("start_date", from: args).flatMap { parseISO8601($0) } ?? Date()
        let endDate = optionalString("end_date", from: args).flatMap { parseISO8601($0) } ?? Date().addingTimeInterval(24 * 3600)

        try await ensureCalendarAccess()

        // Optional calendar filter
        var calendars: [EKCalendar]? = nil
        if let calName = optionalString("calendar_name", from: args),
           let cal = findCalendar(named: calName, type: .event) {
            calendars = [cal]
        }

        let predicate = sharedEventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        var events = sharedEventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        // Text filter
        if let search = searchText {
            events = events.filter { ($0.title ?? "").lowercased().contains(search) }
        }

        let limited = Array(events.prefix(limit))

        if limited.isEmpty {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, h:mm a"
            return "No events found between \(dateFormatter.string(from: startDate)) and \(dateFormatter.string(from: endDate))."
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMM d"
        let fullFmt = DateFormatter()
        fullFmt.dateFormat = "MMM d, h:mm a"

        // Group events by day for readability
        var currentDay = ""
        var lines: [String] = []

        for event in limited {
            let dayStr = dateFmt.string(from: event.startDate)
            if dayStr != currentDay {
                if !currentDay.isEmpty { lines.append("") }
                lines.append("**\(dayStr)**")
                currentDay = dayStr
            }

            var line: String
            if event.isAllDay {
                line = "  - [All Day] \(event.title ?? "Untitled")"
            } else {
                let start = timeFmt.string(from: event.startDate)
                let end = timeFmt.string(from: event.endDate)
                line = "  - \(start)–\(end): \(event.title ?? "Untitled")"
            }

            // Calendar name
            if let calTitle = event.calendar?.title {
                line += " [\(calTitle)]"
            }

            // Location
            if let location = event.location, !location.isEmpty {
                line += " @ \(location)"
            }

            // Notes preview (first 80 chars)
            if let notes = event.notes, !notes.isEmpty {
                let preview = String(notes.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                line += " — \(preview)\(notes.count > 80 ? "..." : "")"
            }

            // Event identifier for update/delete operations
            line += " (id: \(event.eventIdentifier ?? "none"))"

            lines.append(line)
        }

        let total = events.count
        var header = "Events (\(limited.count)"
        if total > limited.count { header += " of \(total)" }
        header += "):"
        return "\(header)\n\(lines.joined(separator: "\n"))"
    }
}

struct UpdateCalendarEventTool: ToolDefinition {
    let name = "update_calendar_event"
    let description = "Update an existing calendar event by its event ID (from query_calendar_events). Can change title, time, location, notes, etc."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "event_id": JSONSchema.string(description: "The event identifier (from query_calendar_events output)"),
            "title": JSONSchema.string(description: "New title for the event"),
            "start_date": JSONSchema.string(description: "New start date in ISO 8601 format"),
            "end_date": JSONSchema.string(description: "New end date in ISO 8601 format"),
            "location": JSONSchema.string(description: "New location"),
            "notes": JSONSchema.string(description: "New notes/description"),
            "url": JSONSchema.string(description: "New URL"),
            "all_day": JSONSchema.boolean(description: "Change to all-day event or timed event"),
            "alert_minutes": JSONSchema.integer(description: "Set alert minutes before event (replaces existing alerts)", minimum: 0, maximum: 10080)
        ], required: ["event_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let eventId = try requiredString("event_id", from: args)

        try await ensureCalendarAccess()

        guard let event = sharedEventStore.event(withIdentifier: eventId) else {
            return "Event not found with ID: \(eventId). Use query_calendar_events to find the correct event ID."
        }

        if let title = optionalString("title", from: args) { event.title = title }
        if let notes = optionalString("notes", from: args) { event.notes = notes }
        if let location = optionalString("location", from: args) { event.location = location }
        if let allDay = optionalBool("all_day", from: args) { event.isAllDay = allDay }
        if let urlStr = optionalString("url", from: args), let url = URL(string: urlStr) { event.url = url }
        if let startStr = optionalString("start_date", from: args), let d = parseISO8601(startStr) { event.startDate = d }
        if let endStr = optionalString("end_date", from: args), let d = parseISO8601(endStr) { event.endDate = d }

        if let alertMins = optionalInt("alert_minutes", from: args) {
            // Remove existing alarms and set new one
            event.alarms?.forEach { event.removeAlarm($0) }
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMins * 60)))
        }

        try sharedEventStore.save(event, span: .thisEvent)
        return "Updated event: \"\(event.title ?? "Untitled")\""
    }
}

struct DeleteCalendarEventTool: ToolDefinition {
    let name = "delete_calendar_event"
    let description = "Delete a calendar event by its event ID (from query_calendar_events)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "event_id": JSONSchema.string(description: "The event identifier (from query_calendar_events output)")
        ], required: ["event_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let eventId = try requiredString("event_id", from: args)

        try await ensureCalendarAccess()

        guard let event = sharedEventStore.event(withIdentifier: eventId) else {
            return "Event not found with ID: \(eventId). Use query_calendar_events to find the correct event ID."
        }

        let title = event.title ?? "Untitled"
        try sharedEventStore.remove(event, span: .thisEvent)
        return "Deleted event: \"\(title)\""
    }
}

// MARK: - Reminder Tools

struct ListReminderListsTool: ToolDefinition {
    let name = "list_reminder_lists"
    let description = "List all reminder lists available on this Mac"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        try await ensureReminderAccess()
        let lists = sharedEventStore.calendars(for: .reminder).sorted { $0.title < $1.title }
        if lists.isEmpty { return "No reminder lists found." }

        let lines = lists.map { list -> String in
            let src = list.source?.title ?? "Unknown"
            let defaultMarker = (list == sharedEventStore.defaultCalendarForNewReminders()) ? " (default)" : ""
            return "- \(list.title) [\(src)]\(defaultMarker)"
        }
        return "Reminder Lists (\(lists.count)):\n\(lines.joined(separator: "\n"))"
    }
}

struct CreateReminderTool: ToolDefinition {
    let name = "create_reminder"
    let description = "Create a new reminder in the Reminders app. Can specify list, priority, due date, and notes."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The reminder title"),
            "notes": JSONSchema.string(description: "Optional notes for the reminder"),
            "due_date": JSONSchema.string(description: "Optional due date in ISO 8601 format (e.g., 2026-04-05T10:00:00)"),
            "list_name": JSONSchema.string(description: "Name of the reminder list to add to (default: system default list). Use list_reminder_lists to see options."),
            "priority": JSONSchema.integer(description: "Priority: 0=none, 1=high, 5=medium, 9=low", minimum: 0, maximum: 9)
        ], required: ["title"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let notes = optionalString("notes", from: args)
        let dueDateStr = optionalString("due_date", from: args)

        try await ensureReminderAccess()

        let reminder = EKReminder(eventStore: sharedEventStore)
        reminder.title = title
        reminder.notes = notes

        // List selection
        if let listName = optionalString("list_name", from: args),
           let list = findCalendar(named: listName, type: .reminder) {
            reminder.calendar = list
        } else {
            reminder.calendar = sharedEventStore.defaultCalendarForNewReminders()
        }

        // Priority
        if let priority = optionalInt("priority", from: args) {
            reminder.priority = priority
        }

        // Due date
        if let dateStr = dueDateStr, let date = parseISO8601(dateStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date
            )
            // Also add an alarm at the due date so the user gets notified
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }

        try sharedEventStore.save(reminder, commit: true)
        let listName = reminder.calendar?.title ?? "default"
        return "Created reminder: \"\(title)\" in list \"\(listName)\""
    }
}

struct QueryRemindersTool: ToolDefinition {
    let name = "query_reminders"
    let description = "Query reminders from the Reminders app. Can filter by list, completion status, and limit results."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "show_completed": JSONSchema.boolean(description: "Whether to show completed reminders (default false = show pending)"),
            "list_name": JSONSchema.string(description: "Optional: only show reminders from this list"),
            "limit": JSONSchema.integer(description: "Maximum number of reminders to return (default 30)", minimum: 1, maximum: 200)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let showCompleted = optionalBool("show_completed", from: args) ?? false
        let limit = optionalInt("limit", from: args) ?? 30

        try await ensureReminderAccess()

        // Optional list filter
        var calendars: [EKCalendar]? = nil
        if let listName = optionalString("list_name", from: args),
           let list = findCalendar(named: listName, type: .reminder) {
            calendars = [list]
        }

        let predicate: NSPredicate
        if showCompleted {
            predicate = sharedEventStore.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
        } else {
            predicate = sharedEventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        }

        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            sharedEventStore.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }

        // Sort: due-date reminders first (earliest first), then no-date ones
        let sorted = reminders.sorted { a, b in
            let dateA = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let dateB = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            if let dA = dateA, let dB = dateB { return dA < dB }
            if dateA != nil { return true }
            return false
        }

        let limited = Array(sorted.prefix(limit))
        if limited.isEmpty {
            return showCompleted ? "No completed reminders found." : "No pending reminders."
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, h:mm a"

        let lines = limited.map { reminder -> String in
            let check = reminder.isCompleted ? "[x]" : "[ ]"
            var line = "\(check) \(reminder.title ?? "Untitled")"

            // Priority
            switch reminder.priority {
            case 1: line += " !!!"    // high
            case 5: line += " !!"     // medium
            case 9: line += " !"      // low
            default: break
            }

            // List name
            if let listTitle = reminder.calendar?.title {
                line += " [\(listTitle)]"
            }

            // Due date
            if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
                line += " (due \(dateFormatter.string(from: date)))"
            }

            // Notes preview
            if let notes = reminder.notes, !notes.isEmpty {
                let preview = String(notes.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                line += " — \(preview)\(notes.count > 60 ? "..." : "")"
            }

            // ID for complete/delete operations
            line += " (id: \(reminder.calendarItemIdentifier))"

            return line
        }

        let status = showCompleted ? "completed" : "pending"
        let total = reminders.count
        var header = "Reminders (\(limited.count)"
        if total > limited.count { header += " of \(total)" }
        header += " \(status)):"
        return "\(header)\n\(lines.joined(separator: "\n"))"
    }
}

struct CompleteReminderTool: ToolDefinition {
    let name = "complete_reminder"
    let description = "Mark a reminder as completed by its ID (from query_reminders)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "reminder_id": JSONSchema.string(description: "The reminder identifier (from query_reminders output)"),
            "uncomplete": JSONSchema.boolean(description: "Set to true to mark a completed reminder as incomplete again (default false)")
        ], required: ["reminder_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let reminderId = try requiredString("reminder_id", from: args)
        let uncomplete = optionalBool("uncomplete", from: args) ?? false

        try await ensureReminderAccess()

        guard let item = sharedEventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return "Reminder not found with ID: \(reminderId). Use query_reminders to find the correct ID."
        }

        item.isCompleted = !uncomplete
        if !uncomplete {
            item.completionDate = Date()
        }
        try sharedEventStore.save(item, commit: true)

        let action = uncomplete ? "Marked as incomplete" : "Completed"
        return "\(action): \"\(item.title ?? "Untitled")\""
    }
}

struct DeleteReminderTool: ToolDefinition {
    let name = "delete_reminder"
    let description = "Delete a reminder by its ID (from query_reminders)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "reminder_id": JSONSchema.string(description: "The reminder identifier (from query_reminders output)")
        ], required: ["reminder_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let reminderId = try requiredString("reminder_id", from: args)

        try await ensureReminderAccess()

        guard let item = sharedEventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return "Reminder not found with ID: \(reminderId). Use query_reminders to find the correct ID."
        }

        let title = item.title ?? "Untitled"
        try sharedEventStore.remove(item, commit: true)
        return "Deleted reminder: \"\(title)\""
    }
}

// MARK: - Notes Tools

struct CreateNoteTool: ToolDefinition {
    let name = "create_note"
    let description = "Create a new note in the Notes app. Can specify which folder to create in."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "The note title"),
            "body": JSONSchema.string(description: "The note body text (supports plain text; newlines with \\n)"),
            "folder": JSONSchema.string(description: "Folder name to create the note in (default: \"Notes\")")
        ], required: ["title", "body"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let body = try requiredString("body", from: args)
        let folder = optionalString("folder", from: args) ?? "Notes"

        // Escape special characters for AppleScript
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedFolder = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            try
                set targetFolder to folder "\(escapedFolder)" of default account
            on error
                set targetFolder to folder "Notes" of default account
            end try
            make new note at targetFolder with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
            return "ok"
        end tell
        """
        try AppleScriptRunner.runThrowing(script)
        return "Created note: \"\(title)\" in folder \"\(folder)\""
    }
}

struct QueryNotesTool: ToolDefinition {
    let name = "query_notes"
    let description = "Search and list notes from the Notes app. Can search by text or list notes in a specific folder."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "search_text": JSONSchema.string(description: "Optional text to search for in note titles and bodies"),
            "folder": JSONSchema.string(description: "Optional folder name to list notes from"),
            "limit": JSONSchema.integer(description: "Maximum number of notes to return (default 20)", minimum: 1, maximum: 100)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let searchText = optionalString("search_text", from: args)
        let folder = optionalString("folder", from: args)
        let limit = optionalInt("limit", from: args) ?? 20

        var script: String
        if let search = searchText {
            let escapedSearch = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                set matchingNotes to {}
                set allNotes to every note of default account
                set noteCount to 0
                repeat with aNote in allNotes
                    if noteCount >= \(limit) then exit repeat
                    set noteName to name of aNote
                    set noteBody to plaintext of aNote
                    if noteName contains "\(escapedSearch)" or noteBody contains "\(escapedSearch)" then
                        set noteId to id of aNote
                        set noteFolder to name of container of aNote
                        set modDate to modification date of aNote
                        set bodyPreview to text 1 thru (min of {120, length of noteBody}) of noteBody
                        set end of matchingNotes to noteId & "|||" & noteName & "|||" & noteFolder & "|||" & (modDate as string) & "|||" & bodyPreview
                        set noteCount to noteCount + 1
                    end if
                end repeat
                set AppleScript's text item delimiters to "\\n"
                return matchingNotes as string
            end tell
            """
        } else if let folderName = folder {
            let escapedFolder = folderName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                set matchingNotes to {}
                try
                    set targetFolder to folder "\(escapedFolder)" of default account
                on error
                    return "Folder not found: \(escapedFolder)"
                end try
                set allNotes to every note of targetFolder
                set noteCount to 0
                repeat with aNote in allNotes
                    if noteCount >= \(limit) then exit repeat
                    set noteId to id of aNote
                    set noteName to name of aNote
                    set noteFolder to name of container of aNote
                    set modDate to modification date of aNote
                    set noteBody to plaintext of aNote
                    set bodyPreview to text 1 thru (min of {120, length of noteBody}) of noteBody
                    set end of matchingNotes to noteId & "|||" & noteName & "|||" & noteFolder & "|||" & (modDate as string) & "|||" & bodyPreview
                    set noteCount to noteCount + 1
                end repeat
                set AppleScript's text item delimiters to "\\n"
                return matchingNotes as string
            end tell
            """
        } else {
            // List recent notes across all folders
            script = """
            tell application "Notes"
                set matchingNotes to {}
                set allNotes to every note of default account
                set noteCount to 0
                repeat with aNote in allNotes
                    if noteCount >= \(limit) then exit repeat
                    set noteId to id of aNote
                    set noteName to name of aNote
                    set noteFolder to name of container of aNote
                    set modDate to modification date of aNote
                    set noteBody to plaintext of aNote
                    set bodyPreview to text 1 thru (min of {120, length of noteBody}) of noteBody
                    set end of matchingNotes to noteId & "|||" & noteName & "|||" & noteFolder & "|||" & (modDate as string) & "|||" & bodyPreview
                    set noteCount to noteCount + 1
                end repeat
                set AppleScript's text item delimiters to "\\n"
                return matchingNotes as string
            end tell
            """
        }

        let result = try AppleScriptRunner.runThrowing(script)

        if result.isEmpty || result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let search = searchText {
                return "No notes found matching \"\(search)\"."
            }
            return "No notes found."
        }

        // Parse the delimited output
        let entries = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lines: [String] = []
        for entry in entries {
            let parts = entry.components(separatedBy: "|||")
            if parts.count >= 5 {
                let noteId = parts[0].trimmingCharacters(in: .whitespaces)
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                let folderName = parts[2].trimmingCharacters(in: .whitespaces)
                let modDate = parts[3].trimmingCharacters(in: .whitespaces)
                let preview = parts[4].trimmingCharacters(in: .whitespaces)
                lines.append("- **\(name)** [\(folderName)] (modified: \(modDate))")
                if !preview.isEmpty {
                    let shortPreview = String(preview.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                    lines.append("  \(shortPreview)\(preview.count > 100 ? "..." : "")")
                }
                lines.append("  (id: \(noteId))")
            } else {
                lines.append("- \(entry)")
            }
        }

        let header = searchText != nil ? "Notes matching \"\(searchText!)\"" : "Notes"
        return "\(header) (\(entries.count)):\n\(lines.joined(separator: "\n"))"
    }
}

struct ReadNoteTool: ToolDefinition {
    let name = "read_note"
    let description = "Read the full content of a specific note by its ID (from query_notes) or by title"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "note_id": JSONSchema.string(description: "The note ID (from query_notes output)"),
            "title": JSONSchema.string(description: "The note title to search for (used if note_id is not provided)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let noteId = optionalString("note_id", from: args)
        let title = optionalString("title", from: args)

        guard noteId != nil || title != nil else {
            return "Please provide either note_id or title."
        }

        var script: String
        if let id = noteId {
            let escapedId = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                try
                    set theNote to note id "\(escapedId)"
                    set noteName to name of theNote
                    set noteBody to plaintext of theNote
                    set noteFolder to name of container of theNote
                    set modDate to modification date of theNote
                    set creDate to creation date of theNote
                    return "TITLE: " & noteName & "\\nFOLDER: " & noteFolder & "\\nCREATED: " & (creDate as string) & "\\nMODIFIED: " & (modDate as string) & "\\n---\\n" & noteBody
                on error errMsg
                    return "Note not found: " & errMsg
                end try
            end tell
            """
        } else {
            let escapedTitle = title!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                try
                    set matchingNotes to (every note of default account whose name contains "\(escapedTitle)")
                    if (count of matchingNotes) = 0 then
                        return "No note found with title containing: \(escapedTitle)"
                    end if
                    set theNote to item 1 of matchingNotes
                    set noteName to name of theNote
                    set noteBody to plaintext of theNote
                    set noteFolder to name of container of theNote
                    set noteId to id of theNote
                    set modDate to modification date of theNote
                    set creDate to creation date of theNote
                    return "TITLE: " & noteName & "\\nFOLDER: " & noteFolder & "\\nID: " & noteId & "\\nCREATED: " & (creDate as string) & "\\nMODIFIED: " & (modDate as string) & "\\n---\\n" & noteBody
                on error errMsg
                    return "Error: " & errMsg
                end try
            end tell
            """
        }

        return try AppleScriptRunner.runThrowing(script)
    }
}

struct UpdateNoteTool: ToolDefinition {
    let name = "update_note"
    let description = "Update an existing note's content. Can replace the body entirely or append to it."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "note_id": JSONSchema.string(description: "The note ID (from query_notes output)"),
            "title": JSONSchema.string(description: "Note title to find (used if note_id not provided)"),
            "new_title": JSONSchema.string(description: "New title for the note"),
            "new_body": JSONSchema.string(description: "New body content (replaces existing body)"),
            "append_body": JSONSchema.string(description: "Text to append to the existing body (ignored if new_body is set)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let noteId = optionalString("note_id", from: args)
        let title = optionalString("title", from: args)
        let newTitle = optionalString("new_title", from: args)
        let newBody = optionalString("new_body", from: args)
        let appendBody = optionalString("append_body", from: args)

        guard noteId != nil || title != nil else {
            return "Please provide either note_id or title."
        }
        guard newTitle != nil || newBody != nil || appendBody != nil else {
            return "Please provide new_title, new_body, or append_body."
        }

        // Build the note-finding part
        let findNote: String
        if let id = noteId {
            let escapedId = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            findNote = "set theNote to note id \"\(escapedId)\""
        } else {
            let escapedTitle = title!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            findNote = """
            set matchingNotes to (every note of default account whose name contains "\(escapedTitle)")
                        if (count of matchingNotes) = 0 then return "Note not found"
                        set theNote to item 1 of matchingNotes
            """
        }

        // Build the update part
        var updateLines: [String] = []
        if let t = newTitle {
            let escaped = t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            updateLines.append("set name of theNote to \"\(escaped)\"")
        }
        if let b = newBody {
            let escaped = b.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            updateLines.append("set body of theNote to \"\(escaped)\"")
        } else if let a = appendBody {
            let escaped = a.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            updateLines.append("set body of theNote to (body of theNote) & \"\\n\" & \"\(escaped)\"")
        }

        let script = """
        tell application "Notes"
            try
                \(findNote)
                \(updateLines.joined(separator: "\n            "))
                return "Updated note: " & name of theNote
            on error errMsg
                return "Error: " & errMsg
            end try
        end tell
        """

        return try AppleScriptRunner.runThrowing(script)
    }
}

struct DeleteNoteTool: ToolDefinition {
    let name = "delete_note"
    let description = "Delete a note by its ID (from query_notes) or by title"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "note_id": JSONSchema.string(description: "The note ID (from query_notes output)"),
            "title": JSONSchema.string(description: "Note title to find and delete (used if note_id not provided)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let noteId = optionalString("note_id", from: args)
        let title = optionalString("title", from: args)

        guard noteId != nil || title != nil else {
            return "Please provide either note_id or title."
        }

        let findNote: String
        if let id = noteId {
            let escapedId = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            findNote = "set theNote to note id \"\(escapedId)\""
        } else {
            let escapedTitle = title!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            findNote = """
            set matchingNotes to (every note of default account whose name contains "\(escapedTitle)")
                        if (count of matchingNotes) = 0 then return "Note not found"
                        set theNote to item 1 of matchingNotes
            """
        }

        let script = """
        tell application "Notes"
            try
                \(findNote)
                set noteName to name of theNote
                delete theNote
                return "Deleted note: " & noteName
            on error errMsg
                return "Error: " & errMsg
            end try
        end tell
        """

        return try AppleScriptRunner.runThrowing(script)
    }
}

struct ListNoteFoldersTool: ToolDefinition {
    let name = "list_note_folders"
    let description = "List all folders in the Notes app"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let script = """
        tell application "Notes"
            set folderList to {}
            repeat with aFolder in every folder of default account
                set folderName to name of aFolder
                set noteCount to count of notes of aFolder
                set end of folderList to folderName & " (" & noteCount & " notes)"
            end repeat
            set AppleScript's text item delimiters to "\\n"
            return folderList as string
        end tell
        """

        let result = try AppleScriptRunner.runThrowing(script)
        if result.isEmpty { return "No folders found in Notes." }

        let folders = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        let lines = folders.map { "- \($0)" }
        return "Note Folders (\(folders.count)):\n\(lines.joined(separator: "\n"))"
    }
}

// MARK: - Timer & Alarm Tools

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

// MARK: - System Settings

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
