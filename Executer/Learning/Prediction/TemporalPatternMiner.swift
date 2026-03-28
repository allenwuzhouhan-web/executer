import Foundation

/// Mines time-based routines from observation history.
/// Detects patterns like "user opens email at 9am every weekday."
enum TemporalPatternMiner {

    /// Mine routines from recent observations.
    static func mineRoutines(from observations: [UserAction], existingRoutines: [Routine] = []) -> [Routine] {
        var routines = existingRoutines

        // Group observations by hour-of-day and day-of-week
        let calendar = Calendar.current
        var hourAppCounts: [Int: [String: Int]] = [:] // hour → app → count
        var dayAppCounts: [Int: [String: Int]] = [:]  // weekday → app → count

        for obs in observations {
            let hour = calendar.component(.hour, from: obs.timestamp)
            let weekday = calendar.component(.weekday, from: obs.timestamp)

            // Only count app switches (first action in each app)
            hourAppCounts[hour, default: [:]][obs.appName, default: 0] += 1
            dayAppCounts[weekday, default: [:]][obs.appName, default: 0] += 1
        }

        // Find consistent time-of-day patterns
        for (hour, apps) in hourAppCounts {
            for (app, count) in apps where count >= 3 {
                let description = "Opens \(app) around \(hour):00"
                let triggerValue = String(format: "%02d:00", hour)

                if let idx = routines.firstIndex(where: { $0.triggerValue == triggerValue && $0.targetApp == app }) {
                    routines[idx].frequency += count
                    routines[idx].confidence = min(Double(routines[idx].frequency) / 10.0, 0.95)
                } else {
                    var routine = Routine(description: description, triggerType: .timeOfDay, triggerValue: triggerValue, actionDescription: "Open \(app)", targetApp: app)
                    routine.frequency = count
                    routine.confidence = min(Double(count) / 10.0, 0.95)
                    routines.append(routine)
                }
            }
        }

        // Sort by confidence and limit
        routines.sort { $0.confidence > $1.confidence }
        return Array(routines.prefix(50))
    }
}
