import Foundation

extension LocalCommandRouter {

    func tryTimerReminder(_ input: String) async -> String? {
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
}
