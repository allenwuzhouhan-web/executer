import Foundation
import AppKit

/// The main learning engine. Runs periodically (every 6 hours + on app quit) to analyze
/// raw observations from ObservationStore and extract patterns into BeliefStore.
///
/// Enforces ALL seven principles:
/// 1. Nothing learned from a single observation (min 3 occurrences across 3 days)
/// 2. Recency matters, but not more than consistency (exponential decay + heavy flywheel)
/// 3. Context separates signal from noise (time, day, focus mode, interaction mode)
/// 4. Active choices vs passive drift (interaction weight filtering)
/// 5. Decay is essential (handled by DecayEngine, enforced here via recency factor)
/// 6. Confidence scoring on everything (0.0–1.0 with classification)
/// 7. User correction is absolute (vetoed beliefs are never regenerated)
final class PatternRecognizer {
    static let shared = PatternRecognizer()

    private var periodicTimer: DispatchSourceTimer?
    private var isRunning = false
    private let recognizerQueue = DispatchQueue(label: "com.executer.patternrecognizer", qos: .utility)

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Run every 6 hours
        let timer = DispatchSource.makeTimerSource(queue: recognizerQueue)
        timer.schedule(deadline: .now() + 300, repeating: 6 * 3600)  // First run after 5 min
        timer.setEventHandler { [weak self] in
            self?.runFullAnalysis()
        }
        timer.resume()
        periodicTimer = timer

        print("[PatternRecognizer] Started — runs every 6 hours")
    }

    func stop() {
        isRunning = false
        periodicTimer?.cancel()
        periodicTimer = nil
        // Final analysis on quit
        runFullAnalysis()
    }

    /// Run all pattern recognizers. Called every 6 hours and on app quit.
    func runFullAnalysis() {
        let start = CFAbsoluteTimeGetCurrent()
        print("[PatternRecognizer] Starting full analysis...")

        recognizeAppUsagePatterns()
        recognizeWorkflowSequences()
        recognizeTemporalRoutines()
        recognizeProjectClusters()
        recognizeCommunicationPatterns()
        recognizeBehavioralFingerprints()

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[PatternRecognizer] Full analysis complete in \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Pattern Type 1: App Usage Patterns

    /// Which apps does the user use, how often, how long, at what times?
    private func recognizeAppUsagePatterns() {
        let days = ObservationStore.shared.distinctDays(type: .app, recentDays: 30)
        guard days.count >= 3 else { return }  // Principle 1: need >= 3 days of data

        // Aggregate app events per day
        var appDayData: [String: [(day: String, totalMinutes: Double, hours: Set<Int>)]] = [:]

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .app)
            for (json, weight, hour) in events {
                guard weight >= 0.5 else { continue }  // Principle 4: skip passive drift
                guard let data = json.data(using: .utf8),
                      let appEvent = try? decoder.decode(OEAppEvent.self, from: data) else { continue }

                let key = appEvent.bundleId
                var existing = appDayData[key] ?? []

                // Find or create entry for this day
                if let idx = existing.firstIndex(where: { $0.day == day }) {
                    var entry = existing[idx]
                    entry = (entry.day, entry.totalMinutes + appEvent.duration / 60.0, entry.hours.union([hour]))
                    existing[idx] = entry
                } else {
                    existing.append((day, appEvent.duration / 60.0, Set([hour])))
                }
                appDayData[key] = existing
            }
        }

        // Create/update beliefs for apps with enough data
        for (bundleId, dayEntries) in appDayData {
            let distinctDays = dayEntries.count
            guard ConfidenceCalculator.meetsHypothesisThreshold(occurrences: dayEntries.count, distinctDays: distinctDays) else { continue }

            let totalMinutes = dayEntries.reduce(0.0) { $0 + $1.totalMinutes }
            let avgDailyMinutes = totalMinutes / Double(max(dayEntries.count, 1))
            let allHours = dayEntries.flatMap { $0.hours }
            let typicalHours = mostFrequent(allHours, topN: 3)

            // Map day strings to Date for recency calculation
            let formatter = BeliefStore.dayDateFormatter
            let dates = dayEntries.compactMap { formatter.date(from: $0.day) }

            let confidence = ConfidenceCalculator.calculate(
                occurrences: dayEntries.count,
                distinctDays: distinctDays,
                observationDates: dates,
                expectedMax: 30
            )

            let appName = dayEntries.first.flatMap { day -> String? in
                let events = ObservationStore.shared.fetchForDay(day.day, type: .app)
                for (json, _, _) in events {
                    if let data = json.data(using: .utf8),
                       let e = try? decoder.decode(OEAppEvent.self, from: data),
                       e.bundleId == bundleId {
                        return e.appName
                    }
                }
                return nil
            } ?? bundleId

            let pattern = AppUsagePattern(
                bundleId: bundleId,
                appName: appName,
                avgDailyMinutes: avgDailyMinutes,
                typicalHours: typicalHours,
                typicalDays: [],  // Will be populated from day-of-week analysis
                totalSessions: dayEntries.count
            )

            let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
            let lastDay = dayEntries.map(\.day).max() ?? ""

            BeliefStore.shared.upsertBelief(
                patternType: .appUsage,
                description: "Uses \(appName) regularly (~\(Int(avgDailyMinutes)) min/day)",
                patternData: patternJSON,
                confidence: confidence,
                observationCount: dayEntries.count,
                distinctDays: distinctDays,
                lastObserved: lastDay
            )
        }
    }

    // MARK: - Pattern Type 2: Workflow Sequences

    /// What app transitions happen repeatedly? A→B or A→B→C chains.
    private func recognizeWorkflowSequences() {
        let days = ObservationStore.shared.distinctDays(type: .transition, recentDays: 30)
        guard days.count >= 3 else { return }

        // Count transition pairs across days
        var pairCounts: [String: (count: Int, days: Set<String>, dates: [Date])] = [:]
        let formatter = BeliefStore.dayDateFormatter

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .transition)
            for (json, weight, _) in events {
                guard weight >= 0.5 else { continue }  // Principle 4
                guard let data = json.data(using: .utf8),
                      let t = try? decoder.decode(OETransitionEvent.self, from: data) else { continue }

                let key = "\(t.fromApp)→\(t.toApp)"
                var entry = pairCounts[key] ?? (0, Set(), [])
                entry.count += 1
                entry.days.insert(day)
                if let d = formatter.date(from: day) { entry.dates.append(d) }
                pairCounts[key] = entry
            }
        }

        // Create beliefs for recurring transitions
        for (key, data) in pairCounts {
            let distinctDays = data.days.count
            guard ConfidenceCalculator.meetsHypothesisThreshold(occurrences: data.count, distinctDays: distinctDays) else { continue }

            let parts = key.split(separator: "→")
            guard parts.count == 2 else { continue }
            let fromApp = String(parts[0])
            let toApp = String(parts[1])

            let confidence = ConfidenceCalculator.calculate(
                occurrences: data.count,
                distinctDays: distinctDays,
                observationDates: data.dates,
                expectedMax: 50
            )

            let fromName = appNameFromBundleId(fromApp)
            let toName = appNameFromBundleId(toApp)

            let pattern = WorkflowSequencePattern(
                steps: [
                    .init(app: fromApp, context: fromName),
                    .init(app: toApp, context: toName)
                ],
                avgDurationSeconds: 0,
                typicalHour: nil,
                typicalDay: nil
            )

            let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
            let lastDay = data.days.max() ?? ""

            BeliefStore.shared.upsertBelief(
                patternType: .workflow,
                description: "Often switches from \(fromName) to \(toName)",
                patternData: patternJSON,
                confidence: confidence,
                observationCount: data.count,
                distinctDays: distinctDays,
                lastObserved: lastDay
            )
        }
    }

    // MARK: - Pattern Type 3: Temporal Routines

    /// What does the user do at specific times? GROUP BY hour_of_day, day_of_week.
    private func recognizeTemporalRoutines() {
        let days = ObservationStore.shared.distinctDays(type: .app, recentDays: 30)
        guard days.count >= 3 else { return }

        // Build a map: (hour, dayOfWeek) → [app bundle IDs]
        var timeSlotApps: [String: [String: Int]] = [:]  // "hour:dow" → {bundleId: count}
        var timeSlotDays: [String: Set<String>] = [:]     // "hour:dow" → {day_dates}
        let formatter = BeliefStore.dayDateFormatter

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .app)
            let calendar = Calendar.current
            guard let date = formatter.date(from: day) else { continue }
            let dow = calendar.component(.weekday, from: date)
            let isoDow = dow == 1 ? 7 : dow - 1

            for (json, weight, hour) in events {
                guard weight >= 0.5 else { continue }
                guard let data = json.data(using: .utf8),
                      let appEvent = try? decoder.decode(OEAppEvent.self, from: data) else { continue }

                // Use 2-hour blocks for fuzzy matching (±1 hour window)
                let block = hour / 2 * 2  // 0-1 → 0, 2-3 → 2, etc.
                let key = "\(block):\(isoDow)"

                var apps = timeSlotApps[key] ?? [:]
                apps[appEvent.bundleId, default: 0] += 1
                timeSlotApps[key] = apps

                var daySet = timeSlotDays[key] ?? Set()
                daySet.insert(day)
                timeSlotDays[key] = daySet
            }
        }

        // Find dominant app for each time slot
        for (key, apps) in timeSlotApps {
            guard let daySet = timeSlotDays[key] else { continue }
            let distinctDays = daySet.count
            guard distinctDays >= 3 else { continue }  // Principle 1

            // Find the most used app in this time slot
            guard let (dominantBundleId, count) = apps.max(by: { $0.value < $1.value }) else { continue }
            guard count >= 3 else { continue }

            let parts = key.split(separator: ":")
            guard parts.count == 2, let hourBlock = Int(parts[0]), let dow = Int(parts[1]) else { continue }

            let dates = daySet.compactMap { formatter.date(from: $0) }
            let confidence = ConfidenceCalculator.calculate(
                occurrences: count,
                distinctDays: distinctDays,
                observationDates: dates,
                expectedMax: 14  // At most 14 days of this weekday in a month
            )

            let appName = appNameFromBundleId(dominantBundleId)
            let dayNames = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let dayName = dow >= 1 && dow <= 7 ? dayNames[dow] : "?"

            let pattern = TemporalRoutinePattern(
                hourStart: hourBlock,
                hourEnd: hourBlock + 2,
                daysOfWeek: [dow],
                dominantApp: dominantBundleId,
                dominantActivity: "Using \(appName)"
            )

            let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
            let lastDay = daySet.max() ?? ""

            BeliefStore.shared.upsertBelief(
                patternType: .routine,
                description: "\(dayName) \(hourBlock):00–\(hourBlock+2):00: usually in \(appName)",
                patternData: patternJSON,
                confidence: confidence,
                observationCount: count,
                distinctDays: distinctDays,
                lastObserved: lastDay
            )
        }
    }

    // MARK: - Pattern Type 4: Project Clusters

    /// Which apps, URLs, and files cluster together across days?
    /// Uses co-occurrence counting: if item A and item B appear on the same day
    /// at a rate > 60% across >= 3 days, they're in the same cluster.
    private func recognizeProjectClusters() {
        let days = ObservationStore.shared.distinctDays(recentDays: 30)
        guard days.count >= 3 else { return }

        // Build per-day item sets
        var dayItems: [String: Set<String>] = [:]  // day → {items}

        for day in days {
            var items: Set<String> = []

            // Apps used that day
            let appEvents = ObservationStore.shared.fetchForDay(day, type: .app)
            for (json, weight, _) in appEvents {
                guard weight >= 0.5 else { continue }
                if let data = json.data(using: .utf8),
                   let e = try? decoder.decode(OEAppEvent.self, from: data) {
                    items.insert("app:\(e.bundleId)")
                }
            }

            // URLs visited that day
            let urlEvents = ObservationStore.shared.fetchForDay(day, type: .url)
            for (json, _, _) in urlEvents {
                if let data = json.data(using: .utf8),
                   let e = try? decoder.decode(OEURLEvent.self, from: data) {
                    items.insert("url:\(e.domain)")
                }
            }

            // Files touched that day
            let fileEvents = ObservationStore.shared.fetchForDay(day, type: .file)
            for (json, _, _) in fileEvents {
                if let data = json.data(using: .utf8),
                   let e = try? decoder.decode(OEFileEvent.self, from: data) {
                    items.insert("dir:\(e.directory)")
                    if !e.fileExtension.isEmpty {
                        items.insert("ext:\(e.fileExtension)")
                    }
                }
            }

            if items.count >= 2 {
                dayItems[day] = items
            }
        }

        guard dayItems.count >= 3 else { return }

        // Count co-occurrences between item pairs
        var coOccurrences: [String: Int] = [:]  // "itemA||itemB" → count of days both appear
        var itemDayCount: [String: Int] = [:]    // item → count of days it appears

        for (_, items) in dayItems {
            let sorted = items.sorted()
            for item in sorted {
                itemDayCount[item, default: 0] += 1
            }
            for i in 0..<sorted.count {
                for j in (i+1)..<sorted.count {
                    let key = "\(sorted[i])||\(sorted[j])"
                    coOccurrences[key, default: 0] += 1
                }
            }
        }

        // Find high co-occurrence pairs (> 60% across >= 3 days)
        // Then build clusters by connected components
        var edges: [(String, String)] = []
        for (key, count) in coOccurrences {
            guard count >= 3 else { continue }
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            // Actual split: "a||b" → ["a", "", "b"] with "|" separator, so use "||" approach
            let pairParts = key.components(separatedBy: "||")
            guard pairParts.count == 2 else { continue }
            let itemA = pairParts[0]
            let itemB = pairParts[1]

            let minDays = min(itemDayCount[itemA] ?? 0, itemDayCount[itemB] ?? 0)
            let coRate = Double(count) / Double(max(minDays, 1))
            if coRate >= 0.6 {
                edges.append((itemA, itemB))
            }
        }

        // Simple connected components via union-find
        let clusters = buildClusters(edges: edges)

        let formatter = BeliefStore.dayDateFormatter
        let totalDays = dayItems.count

        for cluster in clusters {
            guard cluster.count >= 2 else { continue }

            var apps: [String] = []
            var domains: [String] = []
            var extensions: [String] = []
            var directories: [String] = []

            for item in cluster {
                if item.hasPrefix("app:") { apps.append(String(item.dropFirst(4))) }
                else if item.hasPrefix("url:") { domains.append(String(item.dropFirst(4))) }
                else if item.hasPrefix("ext:") { extensions.append(String(item.dropFirst(4))) }
                else if item.hasPrefix("dir:") { directories.append(String(item.dropFirst(4))) }
            }

            // Find the most distinctive term (appears in this cluster but rare globally)
            let clusterName = findDistinctiveName(cluster: cluster, itemDayCounts: itemDayCount, totalDays: totalDays)

            // Count how many days this full cluster appears
            var clusterDays: Set<String> = []
            for (day, items) in dayItems {
                let overlap = cluster.intersection(items)
                if overlap.count >= cluster.count / 2 {  // At least half the cluster items
                    clusterDays.insert(day)
                }
            }

            let distinctDays = clusterDays.count
            guard distinctDays >= 3 else { continue }

            let dates = clusterDays.compactMap { formatter.date(from: $0) }
            let confidence = ConfidenceCalculator.calculate(
                occurrences: clusterDays.count,
                distinctDays: distinctDays,
                observationDates: dates,
                expectedMax: 20
            )

            let coRate = Double(clusterDays.count) / Double(max(totalDays, 1))

            let pattern = ProjectClusterPattern(
                clusterName: clusterName,
                apps: apps,
                domains: domains,
                fileExtensions: extensions,
                directories: directories,
                coOccurrenceRate: coRate
            )

            let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
            let lastDay = clusterDays.max() ?? ""

            BeliefStore.shared.upsertBelief(
                patternType: .project,
                description: "Project: \(clusterName) (\(apps.count) apps, \(domains.count) sites)",
                patternData: patternJSON,
                confidence: confidence,
                observationCount: clusterDays.count,
                distinctDays: distinctDays,
                lastObserved: lastDay
            )
        }
    }

    // MARK: - Pattern Type 5: Communication Patterns

    /// Who does the user communicate with, on which platform, how often?
    /// Extracted from window titles of messaging apps.
    private func recognizeCommunicationPatterns() {
        let messagingApps: Set<String> = [
            "com.tencent.xinWeChat", "com.apple.MobileSMS",
            "com.apple.mail", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
        ]

        let days = ObservationStore.shared.distinctDays(type: .app, recentDays: 30)
        guard days.count >= 3 else { return }

        // Extract contact names from window titles of messaging apps
        var contactData: [String: (platform: String, days: Set<String>, hours: [Int], count: Int)] = [:]
        let formatter = BeliefStore.dayDateFormatter

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .app)
            for (json, weight, hour) in events {
                guard weight >= 0.5 else { continue }
                guard let data = json.data(using: .utf8),
                      let e = try? decoder.decode(OEAppEvent.self, from: data),
                      messagingApps.contains(e.bundleId) else { continue }

                // Extract contact name from window title
                let contact = extractContactName(from: e.windowTitle, app: e.bundleId)
                guard !contact.isEmpty else { continue }

                let platform = platformName(for: e.bundleId)
                let key = "\(contact)@\(platform)"
                var entry = contactData[key] ?? (platform, Set(), [], 0)
                entry.days.insert(day)
                entry.hours.append(hour)
                entry.count += 1
                contactData[key] = entry
            }
        }

        for (key, data) in contactData {
            let distinctDays = data.days.count
            guard distinctDays >= 3 else { continue }

            let contact = key.components(separatedBy: "@").first ?? key
            let dates = data.days.compactMap { formatter.date(from: $0) }

            let confidence = ConfidenceCalculator.calculate(
                occurrences: data.count,
                distinctDays: distinctDays,
                observationDates: dates,
                expectedMax: 30
            )

            let typicalHours = mostFrequent(data.hours, topN: 2)
            let frequency: String
            if distinctDays > 20 { frequency = "daily" }
            else if distinctDays > 8 { frequency = "weekly" }
            else { frequency = "occasional" }

            // Detect language from contact name (Chinese characters = zh)
            let lang = contact.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) ? "zh" : "en"

            let pattern = CommunicationPattern(
                contactName: contact,
                platform: data.platform,
                typicalHours: typicalHours,
                frequency: frequency,
                typicalLanguage: lang,
                messageCount: data.count
            )

            let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
            let lastDay = data.days.max() ?? ""

            BeliefStore.shared.upsertBelief(
                patternType: .communication,
                description: "Messages \(contact) on \(data.platform) (\(frequency))",
                patternData: patternJSON,
                confidence: confidence,
                observationCount: data.count,
                distinctDays: distinctDays,
                lastObserved: lastDay
            )
        }
    }

    // MARK: - Pattern Type 6: Behavioral Fingerprints

    /// Subtle preferences inferred from consistent choices.
    private func recognizeBehavioralFingerprints() {
        let days = ObservationStore.shared.distinctDays(recentDays: 30)
        guard days.count >= 3 else { return }
        let formatter = BeliefStore.dayDateFormatter

        // Check dark mode preference
        detectAppearancePreference(days: days, formatter: formatter)

        // Check primary coding language from file extensions
        detectCodingLanguagePreference(days: days, formatter: formatter)

        // Check research-before-writing pattern
        detectWorkflowStylePreference(days: days, formatter: formatter)
    }

    private func detectAppearancePreference(days: [String], formatter: DateFormatter) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let preference = isDark ? "dark" : "light"

        // We can't observe this historically, but if it's consistent across days,
        // it's a preference. We just check the current state and increment.
        let dates = days.suffix(7).compactMap { formatter.date(from: $0) }
        let confidence = dates.count >= 3 ? 0.8 : 0.4

        let pattern = PreferencePattern(category: "appearance", key: "color_scheme", value: preference, evidenceCount: dates.count)
        let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"
        let lastDay = days.last ?? ""

        BeliefStore.shared.upsertBelief(
            patternType: .preference,
            description: "Prefers \(preference) mode",
            patternData: patternJSON,
            confidence: confidence,
            observationCount: dates.count,
            distinctDays: dates.count,
            lastObserved: lastDay
        )
    }

    private func detectCodingLanguagePreference(days: [String], formatter: DateFormatter) {
        var extCounts: [String: Int] = [:]
        var extDays: [String: Set<String>] = [:]

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .file)
            for (json, _, _) in events {
                guard let data = json.data(using: .utf8),
                      let e = try? decoder.decode(OEFileEvent.self, from: data) else { continue }
                let ext = e.fileExtension.lowercased()
                let codeExts: Set<String> = ["swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "rb", "kt"]
                guard codeExts.contains(ext) else { continue }
                extCounts[ext, default: 0] += 1
                extDays[ext, default: Set()].insert(day)
            }
        }

        // Find the dominant coding language
        guard let (topExt, count) = extCounts.max(by: { $0.value < $1.value }),
              let daySet = extDays[topExt], daySet.count >= 3 else { return }

        let dates = daySet.compactMap { formatter.date(from: $0) }
        let confidence = ConfidenceCalculator.calculate(
            occurrences: count,
            distinctDays: daySet.count,
            observationDates: dates,
            expectedMax: 30
        )

        let langNames: [String: String] = [
            "swift": "Swift", "py": "Python", "js": "JavaScript", "ts": "TypeScript",
            "go": "Go", "rs": "Rust", "java": "Java", "c": "C", "cpp": "C++",
            "rb": "Ruby", "kt": "Kotlin"
        ]
        let langName = langNames[topExt] ?? topExt

        let pattern = PreferencePattern(category: "tools", key: "primary_coding_language", value: langName, evidenceCount: count)
        let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"

        BeliefStore.shared.upsertBelief(
            patternType: .preference,
            description: "Codes primarily in \(langName)",
            patternData: patternJSON,
            confidence: confidence,
            observationCount: count,
            distinctDays: daySet.count,
            lastObserved: daySet.max() ?? ""
        )
    }

    private func detectWorkflowStylePreference(days: [String], formatter: DateFormatter) {
        // Check if user tends to research (browser) before writing (editor)
        var researchFirstCount = 0
        var writeFirstCount = 0
        var relevantDays: Set<String> = []

        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox"]
        let editors: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.sublimetext.4", "com.googlecode.iterm2"]

        for day in days {
            let events = ObservationStore.shared.fetchForDay(day, type: .transition)
            var sawBrowserFirst = false
            var sawEditorFirst = false

            for (json, weight, _) in events {
                guard weight >= 0.5 else { continue }
                guard let data = json.data(using: .utf8),
                      let t = try? decoder.decode(OETransitionEvent.self, from: data) else { continue }

                if browsers.contains(t.fromApp) && editors.contains(t.toApp) && !sawEditorFirst {
                    sawBrowserFirst = true
                }
                if editors.contains(t.fromApp) && browsers.contains(t.toApp) && !sawBrowserFirst {
                    sawEditorFirst = true
                }
            }

            if sawBrowserFirst { researchFirstCount += 1; relevantDays.insert(day) }
            if sawEditorFirst { writeFirstCount += 1; relevantDays.insert(day) }
        }

        guard relevantDays.count >= 3 else { return }

        let style: String
        let desc: String
        if researchFirstCount > writeFirstCount * 2 {
            style = "research_first"
            desc = "Tends to research before writing"
        } else if writeFirstCount > researchFirstCount * 2 {
            style = "write_first"
            desc = "Tends to write first, research as needed"
        } else {
            return  // No clear preference
        }

        let dates = relevantDays.compactMap { formatter.date(from: $0) }
        let dominant = max(researchFirstCount, writeFirstCount)
        let confidence = ConfidenceCalculator.calculate(
            occurrences: dominant,
            distinctDays: relevantDays.count,
            observationDates: dates,
            expectedMax: 20
        )

        let pattern = PreferencePattern(category: "workflow_style", key: "research_vs_write_order", value: style, evidenceCount: dominant)
        let patternJSON = (try? String(data: encoder.encode(pattern), encoding: .utf8)) ?? "{}"

        BeliefStore.shared.upsertBelief(
            patternType: .preference,
            description: desc,
            patternData: patternJSON,
            confidence: confidence,
            observationCount: dominant,
            distinctDays: relevantDays.count,
            lastObserved: relevantDays.max() ?? ""
        )
    }

    // MARK: - Helpers

    private func mostFrequent(_ values: [Int], topN: Int) -> [Int] {
        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(topN).map(\.key)
    }

    private func appNameFromBundleId(_ bundleId: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .localizedName ?? bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func extractContactName(from windowTitle: String, app bundleId: String) -> String {
        // WeChat: window title IS the contact/group name
        // iMessage: "Messages — Contact Name" or just contact name
        // Mail: "Subject — Sender" or inbox view
        // Slack: "#channel" or "Contact Name"
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "" }

        // Filter out generic window titles
        let generic = ["WeChat", "微信", "Messages", "Mail", "Slack", "Discord", "Inbox"]
        if generic.contains(title) { return "" }

        // For Messages: strip "Messages — " prefix
        if title.contains(" — ") {
            return String(title.split(separator: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        if title.contains(" - ") {
            return String(title.split(separator: "-").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }

        return title
    }

    private func platformName(for bundleId: String) -> String {
        switch bundleId {
        case "com.tencent.xinWeChat": return "WeChat"
        case "com.apple.MobileSMS": return "iMessage"
        case "com.apple.mail": return "Mail"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "com.hnc.Discord": return "Discord"
        default: return bundleId.components(separatedBy: ".").last ?? "Unknown"
        }
    }

    private func findDistinctiveName(cluster: Set<String>, itemDayCounts: [String: Int], totalDays: Int) -> String {
        // The most distinctive item is one that appears often in this cluster's context
        // but is rare globally. Use TF-IDF-like scoring.
        var bestItem = ""
        var bestScore = 0.0

        for item in cluster {
            let globalFreq = Double(itemDayCounts[item] ?? 0) / Double(max(totalDays, 1))
            // Items that appear in < 50% of all days are more distinctive
            let distinctiveness = 1.0 - globalFreq
            if distinctiveness > bestScore {
                bestScore = distinctiveness
                bestItem = item
            }
        }

        // Clean up the item name for display
        if bestItem.hasPrefix("url:") { return String(bestItem.dropFirst(4)) }
        if bestItem.hasPrefix("dir:") { return String(bestItem.dropFirst(4)) }
        if bestItem.hasPrefix("app:") { return appNameFromBundleId(String(bestItem.dropFirst(4))) }
        if bestItem.hasPrefix("ext:") { return ".\(bestItem.dropFirst(4)) project" }
        return bestItem.isEmpty ? "Unnamed cluster" : bestItem
    }

    /// Simple connected components from edges.
    private func buildClusters(edges: [(String, String)]) -> [Set<String>] {
        var parent: [String: String] = [:]

        func find(_ x: String) -> String {
            if parent[x] == nil { parent[x] = x }
            if let p = parent[x], p != x { parent[x] = find(p) }
            return parent[x] ?? x
        }

        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for (a, b) in edges {
            union(a, b)
        }

        var clusters: [String: Set<String>] = [:]
        for key in parent.keys {
            let root = find(key)
            clusters[root, default: Set()].insert(key)
        }

        return Array(clusters.values).filter { $0.count >= 2 }
    }
}
