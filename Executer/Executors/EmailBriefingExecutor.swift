import Foundation
import AppKit

// MARK: - Send Email Briefing

struct SendEmailBriefingTool: ToolDefinition {
    let name = "send_email_briefing"
    let description = """
        Compose and send an email briefing via Mail.app. Provide structured sections \
        (headlines, calendar, tasks, custom) and the tool formats them into a clean HTML email. \
        Use this after gathering data with other tools (fetch_url_content, query_calendar_events, etc.).
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "to": JSONSchema.string(description: "Recipient email address(es), comma-separated"),
            "subject": JSONSchema.string(description: "Email subject line"),
            "sections": JSONSchema.array(items: JSONSchema.object(properties: [
                "title": JSONSchema.string(description: "Section heading (e.g., 'Top Headlines', 'Today\\'s Calendar')"),
                "items": JSONSchema.array(items: JSONSchema.string(description: "A single item/bullet"), description: "Bullet points or items in this section"),
            ], required: ["title", "items"]), description: "Array of briefing sections"),
            "greeting": JSONSchema.string(description: "Opening line (default: 'Here is your briefing')"),
            "sign_off": JSONSchema.string(description: "Closing line (default: 'Have a great day!')"),
        ], required: ["to", "subject", "sections"])
    }

    func execute(arguments: String) async throws -> String {
        if let err = ensureMailAvailable() { return err }
        let args = try parseArguments(arguments)
        let to = try requiredString("to", from: args)
        let subject = try requiredString("subject", from: args)
        let greeting = optionalString("greeting", from: args) ?? "Here is your briefing"
        let signOff = optionalString("sign_off", from: args) ?? "Have a great day!"

        guard let sectionsRaw = args["sections"] as? [[String: Any]], !sectionsRaw.isEmpty else {
            return "Error: 'sections' must be a non-empty array of {title, items} objects."
        }

        // Build HTML body
        var html = """
        <div style="font-family: -apple-system, Helvetica, Arial, sans-serif; max-width: 600px; margin: 0 auto; color: #333;">
        <p style="font-size: 16px; color: #555;">\(escapeHTML(greeting))</p>
        """

        for section in sectionsRaw {
            let title = section["title"] as? String ?? "Section"
            let items = (section["items"] as? [String]) ?? []

            html += """
            <div style="margin: 20px 0;">
            <h2 style="font-size: 18px; color: #1a1a1a; border-bottom: 2px solid #007AFF; padding-bottom: 6px; margin-bottom: 10px;">\(escapeHTML(title))</h2>
            <ul style="padding-left: 20px; line-height: 1.6;">
            """
            for item in items {
                html += "<li style=\"margin-bottom: 6px;\">\(escapeHTML(item))</li>\n"
            }
            html += "</ul></div>\n"
        }

        html += """
        <p style="font-size: 14px; color: #888; margin-top: 30px; border-top: 1px solid #eee; padding-top: 10px;">\(escapeHTML(signOff))</p>
        </div>
        """

        // Send via Mail.app AppleScript
        return try sendHTMLEmail(to: to, subject: subject, htmlBody: html)
    }

    private func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Schedule Email Briefing

struct ScheduleEmailBriefingTool: ToolDefinition {
    let name = "schedule_email_briefing"
    let description = """
        Schedule a recurring email briefing. The briefing will be assembled and sent automatically \
        at the specified time using a background agent. Topics define what data to gather.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "name": JSONSchema.string(description: "Name for this briefing (e.g., 'Morning Digest')"),
            "to": JSONSchema.string(description: "Recipient email address(es), comma-separated"),
            "topics": JSONSchema.string(description: "What to include — the AI will gather this data (e.g., 'top tech news, today\\'s calendar events, weather')"),
            "frequency": JSONSchema.enumString(description: "How often to send", values: ["daily", "weekly", "weekdays"]),
            "time": JSONSchema.string(description: "Time to send in HH:MM 24h format (e.g., '07:30')"),
        ], required: ["name", "to", "topics", "frequency", "time"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("name", from: args)
        let to = try requiredString("to", from: args)
        let topics = try requiredString("topics", from: args)
        let frequency = try requiredString("frequency", from: args)
        let time = try requiredString("time", from: args)

        // Validate time format
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return "Invalid time format. Use HH:MM (24h), e.g., '07:30'."
        }

        // Load existing schedules
        var schedules = EmailBriefingStore.load()

        // Check for duplicate name
        if schedules.contains(where: { $0.name == name }) {
            return "A briefing named '\(name)' already exists. Use a different name or cancel the existing one first."
        }

        let schedule = EmailBriefingSchedule(
            id: UUID(), name: name, to: to, topics: topics,
            frequency: frequency, time: time, enabled: true,
            createdAt: Date()
        )
        schedules.append(schedule)
        EmailBriefingStore.save(schedules)

        // Start a background agent to handle the schedule
        let command = "Compose and send an email briefing to \(to) about: \(topics). Use fetch_url_content for news, query_calendar_events for calendar, then call send_email_briefing with the gathered data. Subject: '\(name) — \\(Date().formatted(date: .abbreviated, time: .omitted))'"
        let interval = frequency == "daily" || frequency == "weekdays" ? 86400 : 604800

        _ = await BackgroundAgentManager.shared.startAgent(
            goal: "Email briefing: \(name)",
            trigger: .poll(intervalSeconds: interval, check: command),
            maxLifetimeMinutes: frequency == "weekly" ? 10080 : 1440
        )

        return "Scheduled '\(name)' — \(frequency) at \(time) to \(to). Topics: \(topics). Background agent started."
    }
}

// MARK: - List Email Briefings

struct ListEmailBriefingsTool: ToolDefinition {
    let name = "list_email_briefings"
    let description = "List all scheduled email briefings and their status."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let schedules = EmailBriefingStore.load()
        if schedules.isEmpty { return "No email briefings scheduled." }

        var lines = ["Scheduled email briefings (\(schedules.count)):"]
        for s in schedules {
            let status = s.enabled ? "active" : "paused"
            lines.append("- [\(s.id.uuidString.prefix(8))] \(s.name) — \(s.frequency) at \(s.time) to \(s.to) [\(status)]")
            lines.append("  Topics: \(s.topics)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cancel Email Briefing

struct CancelEmailBriefingTool: ToolDefinition {
    let name = "cancel_email_briefing"
    let description = "Cancel a scheduled email briefing by name or ID prefix."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "name_or_id": JSONSchema.string(description: "Briefing name or first 8 characters of its ID"),
        ], required: ["name_or_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("name_or_id", from: args)

        var schedules = EmailBriefingStore.load()
        let lowered = query.lowercased()

        guard let idx = schedules.firstIndex(where: {
            $0.name.lowercased() == lowered ||
            $0.id.uuidString.lowercased().hasPrefix(lowered)
        }) else {
            return "No briefing found matching '\(query)'."
        }

        let removed = schedules.remove(at: idx)
        EmailBriefingStore.save(schedules)
        return "Cancelled email briefing: \(removed.name)"
    }
}

// MARK: - Shared: Send HTML Email via Mail.app

func sendHTMLEmail(to: String, subject: String, htmlBody: String) throws -> String {
    let escapedSubject = AppleScriptRunner.escape(subject)
    let recipients = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

    // Build recipient creation lines
    let recipientLines = recipients.map { addr in
        "make new to recipient at end of to recipients with properties {address:\"\(AppleScriptRunner.escape(addr))\"}"
    }.joined(separator: "\n                ")

    // Write HTML to temp file — AppleScript will read it
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("briefing_\(UUID().uuidString).html")
    try htmlBody.write(to: tempURL, atomically: true, encoding: .utf8)

    let script = """
    tell application "Mail"
        set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", visible:false}
        tell newMsg
            \(recipientLines)
            set html content to (read POSIX file "\(tempURL.path)" as text)
        end tell
        send newMsg
    end tell
    return "SENT"
    """

    let result = try AppleScriptRunner.runThrowing(script)
    try? FileManager.default.removeItem(at: tempURL)

    if result.contains("SENT") {
        return "Email sent to \(to) with subject '\(subject)'."
    }
    return "Email composed but may not have sent. Check Mail.app outbox."
}

// MARK: - Persistence

struct EmailBriefingSchedule: Codable, Identifiable {
    let id: UUID
    let name: String
    let to: String
    let topics: String
    let frequency: String
    let time: String
    var enabled: Bool
    let createdAt: Date
}

enum EmailBriefingStore {
    private static var storageURL: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("email_briefings.json")
    }

    static func load() -> [EmailBriefingSchedule] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([EmailBriefingSchedule].self, from: data)) ?? []
    }

    static func save(_ schedules: [EmailBriefingSchedule]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(schedules) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
