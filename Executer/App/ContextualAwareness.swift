import Foundation
import EventKit

/// Checks for contextual hints when the input bar opens — upcoming meetings,
/// long work sessions, late nights, low battery, etc. Shows a subtle nudge
/// in the placeholder text so it feels like the Mac actually pays attention.
class ContextualAwareness {
    static let shared = ContextualAwareness()
    private init() {}

    private var sessionStart: Date = Date()
    private var lastNudge: Date = .distantPast
    private let nudgeCooldown: TimeInterval = 600 // Don't nudge more than once per 10 minutes

    /// Called once on app launch to mark the start of the work session.
    func markSessionStart() {
        sessionStart = Date()
    }

    /// Returns a contextual nudge string, or nil if nothing noteworthy.
    /// Called when the input bar opens. Should be fast (< 1 second).
    func checkContext() async -> String? {
        // Don't nudge too frequently
        guard Date().timeIntervalSince(lastNudge) > nudgeCooldown else { return nil }

        // Run checks in priority order — return first match
        if let nudge = checkLateNight() { return record(nudge) }
        if let nudge = checkLongSession() { return record(nudge) }
        if let nudge = checkLowBattery() { return record(nudge) }
        if let nudge = await checkUpcomingMeeting() { return record(nudge) }
        if let nudge = checkWeekend() { return record(nudge) }

        return nil
    }

    private func record(_ nudge: String) -> String {
        lastNudge = Date()
        return nudge
    }

    // MARK: - Checks

    private func checkLateNight() -> String? {
        let hour = Calendar.current.component(.hour, from: Date())
        let humor = HumorMode.shared.isEnabled

        if hour >= 1 && hour < 5 {
            return humor
                ? "bestie it's \(hour) AM... go to sleep"
                : "It's past \(hour) AM — consider getting some rest."
        }
        if hour >= 23 {
            return humor
                ? "it's getting late, don't you have stuff tomorrow?"
                : "It's getting late — need me to set a bedtime reminder?"
        }
        return nil
    }

    private func checkLongSession() -> String? {
        let hoursWorking = Date().timeIntervalSince(sessionStart) / 3600
        let humor = HumorMode.shared.isEnabled

        if hoursWorking >= 4 {
            let h = Int(hoursWorking)
            return humor
                ? "you've been going for \(h) hours straight. touch grass?"
                : "You've been working for \(h) hours — want me to set a break timer?"
        }
        if hoursWorking >= 2 {
            return humor
                ? "2+ hours in, maybe stretch those legs?"
                : "You've been at it for a while — maybe take a quick break?"
        }
        return nil
    }

    private func checkLowBattery() -> String? {
        guard let result = try? ShellRunner.run("pmset -g batt 2>/dev/null", timeout: 3) else { return nil }
        let output = result.output
        guard !output.contains("AC Power") else { return nil } // Plugged in, no warning needed

        if let range = output.range(of: #"\d+"#, options: .regularExpression) {
            let pct = Int(String(output[range])) ?? 100
            let humor = HumorMode.shared.isEnabled
            if pct <= 15 {
                return humor
                    ? "battery at \(pct)%... we're running on fumes here"
                    : "Battery at \(pct)% — you might want to plug in soon."
            }
        }
        return nil
    }

    private func checkUpcomingMeeting() async -> String? {
        let store = EKEventStore()

        // Check authorization without prompting
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let now = Date()
        let soon = now.addingTimeInterval(15 * 60) // next 15 minutes

        let predicate = store.predicateForEvents(withStart: now, end: soon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay } // Skip all-day events
            .sorted { $0.startDate < $1.startDate }

        guard let nextEvent = events.first else { return nil }

        let minutesUntil = Int(nextEvent.startDate.timeIntervalSince(now) / 60)
        let title = nextEvent.title ?? "Event"
        let humor = HumorMode.shared.isEnabled

        if minutesUntil <= 0 {
            // Event is happening now
            return humor
                ? "yo \"\(title)\" is happening RIGHT NOW"
                : "\"\(title)\" is happening now."
        } else if minutesUntil <= 5 {
            return humor
                ? "\"\(title)\" starts in \(minutesUntil) min — RUN"
                : "\"\(title)\" starts in \(minutesUntil) minutes!"
        } else {
            return humor
                ? "heads up — \"\(title)\" in \(minutesUntil) min"
                : "You have \"\(title)\" in \(minutesUntil) minutes."
        }
    }

    private func checkWeekend() -> String? {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let hour = Calendar.current.component(.hour, from: Date())
        let humor = HumorMode.shared.isEnabled

        // Saturday or Sunday, morning
        if (weekday == 1 || weekday == 7) && hour >= 6 && hour <= 10 {
            return humor
                ? "it's the weekend, what are we doing on the computer?"
                : nil // Don't nag on weekends in normal mode
        }
        return nil
    }
}
