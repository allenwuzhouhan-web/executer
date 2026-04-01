import Foundation

extension LocalCommandRouter {

    func tryTimerReminder(_ input: String) async -> String? {
        // ── Alarm: "alarm 6:50PM", "alarm 1850", "alarm 7am", "set alarm 18:50" ──
        if let alarmResult = await tryParseAlarm(input) {
            return alarmResult
        }

        // "set a timer for X minutes" / "timer X minutes" / "X minute timer"
        if input.contains("timer") || input.contains("set a timer") {
            if let seconds = extractTimerSeconds(from: input) {
                return try? await SetTimerTool().execute(arguments: "{\"duration_seconds\": \(seconds), \"label\": \"Timer\"}")
            }
        }

        // "remind me to [task]" / "reminder: [task]"
        let reminderPrefixes = ["remind me to ", "remind me ", "reminder ", "reminder: "]
        for prefix in reminderPrefixes {
            if input.hasPrefix(prefix) {
                let task = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !task.isEmpty {
                    return try? await CreateReminderTool().execute(arguments: "{\"title\": \"\(escapeJSON(task))\"}")
                }
            }
        }

        // "note: [text]" / "take a note [text]" / "make a note [text]"
        let notePrefixes = ["note: ", "note ", "take a note ", "make a note "]
        for prefix in notePrefixes {
            if input.hasPrefix(prefix) {
                let text = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return try? await CreateNoteTool().execute(arguments: "{\"title\": \"Quick Note\", \"body\": \"\(escapeJSON(text))\"}")
                }
            }
        }

        return nil
    }

    // MARK: - Alarm Parsing

    /// Parses alarm commands in many formats:
    /// "alarm 6:50PM", "alarm 6:50pm", "alarm 18:50", "alarm 1850",
    /// "alarm 7am", "alarm 7 AM", "set alarm 6:50 pm", "set alarm for 1850"
    private func tryParseAlarm(_ input: String) async -> String? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)

        // Must start with "alarm" or "set alarm"
        guard lower.hasPrefix("alarm") || lower.hasPrefix("set alarm") || lower.hasPrefix("set an alarm") else {
            return nil
        }

        // Strip the prefix to get the time part
        var timePart = lower
        for prefix in ["set an alarm for ", "set an alarm ", "set alarm for ", "set alarm ", "alarm "] {
            if timePart.hasPrefix(prefix) {
                timePart = String(timePart.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !timePart.isEmpty else { return nil }

        // Try to parse the time
        if let (hour, minute) = parseTimeString(timePart) {
            let timeStr = String(format: "%02d:%02d", hour, minute)
            return try? await SetAlarmTool().execute(arguments: "{\"time\": \"\(timeStr)\", \"label\": \"Alarm\"}")
        }

        return nil
    }

    /// Parse time from various formats into (hour24, minute).
    /// Supports: "6:50pm", "6:50 PM", "18:50", "1850", "7am", "7 am", "7:00am"
    private func parseTimeString(_ raw: String) -> (Int, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()

        // Detect AM/PM
        var isPM = false
        var isAM = false
        var cleaned = s
        if cleaned.hasSuffix("pm") || cleaned.hasSuffix("p.m.") || cleaned.hasSuffix("p.m") {
            isPM = true
            cleaned = cleaned.replacingOccurrences(of: "p.m.", with: "").replacingOccurrences(of: "p.m", with: "").replacingOccurrences(of: "pm", with: "")
        } else if cleaned.hasSuffix("am") || cleaned.hasSuffix("a.m.") || cleaned.hasSuffix("a.m") {
            isAM = true
            cleaned = cleaned.replacingOccurrences(of: "a.m.", with: "").replacingOccurrences(of: "a.m", with: "").replacingOccurrences(of: "am", with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        var hour: Int
        var minute: Int

        if cleaned.contains(":") {
            // "6:50" or "18:50"
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h
            minute = m
        } else if let num = Int(cleaned) {
            if num >= 100 && num <= 2359 {
                // "1850" → 18:50, "650" → 6:50
                hour = num / 100
                minute = num % 100
            } else if num >= 1 && num <= 12 {
                // "7" → 7:00
                hour = num
                minute = 0
            } else {
                return nil
            }
        } else {
            return nil
        }

        // Apply AM/PM conversion
        if isPM && hour < 12 { hour += 12 }
        if isAM && hour == 12 { hour = 0 }

        guard hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
        return (hour, minute)
    }
}
