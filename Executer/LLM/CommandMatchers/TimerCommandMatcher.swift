import Foundation

extension LocalCommandRouter {

    func tryTimerReminder(_ input: String) async -> String? {
        // ── Alarm: "alarm 6:50PM", "alarm 1850", "alarm 7am", "set alarm 18:50" ──
        if let alarmResult = await tryParseAlarm(input) {
            return alarmResult
        }

        // "set a timer for X" / "timer X" / "X timer" — dynamic duration parsing
        if input.contains("timer") || input.hasPrefix("set a timer") {
            if let seconds = Self.parseCompoundDuration(input) {
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

    // MARK: - Compound Duration Parsing

    // Matches individual duration components: "1 hour", "30 minutes", "5 sec", "2h", "15m"
    // Matches duration components. Uses lookahead instead of \b so "2h15m" works (no word boundary between h and 1)
    private static let durationComponentPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?=\d|\s|$)"#,
        options: .caseInsensitive
    )

    // Matches "H:MM" or "H:MM:SS" format: "1:30", "1:30:00"
    private static let colonDurationPattern = try! NSRegularExpression(
        pattern: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#
    )

    /// Parses compound durations into total seconds.
    /// Supports: "1 hour 30 minutes", "90 minutes", "2h15m", "1:30", "1 hour and 30 minutes",
    /// "2 hours 15 minutes and 30 seconds", "45s", "1h30m"
    static func parseCompoundDuration(_ input: String) -> Int? {
        // Try colon format first: "1:30" → 90 minutes, "1:30:00" → 1h 30m
        let nsRange = NSRange(input.startIndex..., in: input)
        if let colonMatch = colonDurationPattern.firstMatch(in: input, range: nsRange) {
            let h = Int(Range(colonMatch.range(at: 1), in: input).flatMap { Int(input[$0]) } ?? 0)
            let m = Int(Range(colonMatch.range(at: 2), in: input).flatMap { Int(input[$0]) } ?? 0)
            let s: Int
            if colonMatch.range(at: 3).location != NSNotFound,
               let sRange = Range(colonMatch.range(at: 3), in: input) {
                s = Int(input[sRange]) ?? 0
            } else {
                s = 0
            }
            let total = h * 3600 + m * 60 + s
            if total > 0 { return total }
        }

        // Parse individual components and sum them
        let matches = durationComponentPattern.matches(in: input, range: nsRange)
        guard !matches.isEmpty else { return nil }

        var totalSeconds = 0
        for match in matches {
            guard let numRange = Range(match.range(at: 1), in: input),
                  let unitRange = Range(match.range(at: 2), in: input),
                  let num = Int(input[numRange]) else { continue }

            let unit = String(input[unitRange]).lowercased()
            if unit.hasPrefix("h") {
                totalSeconds += num * 3600
            } else if unit.hasPrefix("m") {
                totalSeconds += num * 60
            } else if unit.hasPrefix("s") {
                totalSeconds += num
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }

    // MARK: - Alarm Parsing

    /// Parses alarm commands in many formats:
    /// "alarm 6:50PM", "alarm 6:50pm", "alarm 18:50", "alarm 1850",
    /// "alarm 7am", "alarm 7 AM", "set alarm 6:50 pm", "set alarm for 1850"
    private func tryParseAlarm(_ input: String) async -> String? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)

        guard lower.hasPrefix("alarm") || lower.hasPrefix("set alarm") || lower.hasPrefix("set an alarm") else {
            return nil
        }

        var timePart = lower
        for prefix in ["set an alarm for ", "set an alarm ", "set alarm for ", "set alarm ", "alarm "] {
            if timePart.hasPrefix(prefix) {
                timePart = String(timePart.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !timePart.isEmpty else { return nil }

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
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h
            minute = m
        } else if let num = Int(cleaned) {
            if num >= 100 && num <= 2359 {
                hour = num / 100
                minute = num % 100
            } else if num >= 1 && num <= 12 {
                hour = num
                minute = 0
            } else {
                return nil
            }
        } else {
            return nil
        }

        if isPM && hour < 12 { hour += 12 }
        if isAM && hour == 12 { hour = 0 }

        guard hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
        return (hour, minute)
    }
}
