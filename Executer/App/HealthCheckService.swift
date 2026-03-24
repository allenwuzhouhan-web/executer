import Foundation
import Cocoa

/// Runs a daily system health check and surfaces a friendly card via the input bar.
class HealthCheckService {
    static let shared = HealthCheckService()
    private init() {}

    private let lastCheckKey = "last_health_check_date"

    /// Called on app launch. If >24h since last check, gathers stats and shows a card.
    func checkIfDue(appState: AppState) {
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        let hoursSinceCheck = Date().timeIntervalSince(lastCheck) / 3600

        guard hoursSinceCheck >= 24 else {
            print("[HealthCheck] Last check was \(String(format: "%.1f", hoursSinceCheck))h ago, skipping")
            return
        }

        // Wait 5 seconds for UI to settle, then run
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            Task {
                await self.runHealthCheck(appState: appState)
            }
        }
    }

    private func runHealthCheck(appState: AppState) async {
        print("[HealthCheck] Running daily health check...")

        let report = await gatherStats()
        let humor = HumorMode.shared
        let message: String
        if humor.isEnabled {
            let funnyPrefix = humor.funnyHealthMessage(isHealthy: report.isHealthy, diskUsedPercent: report.diskUsedPercent)
            let stats = report.statsLine
            message = "\(funnyPrefix) \u{2014} \(stats)"
        } else {
            message = report.summaryMessage
        }

        print("[HealthCheck] Result: \(message)")

        // Save check date
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        // Show the card
        await MainActor.run {
            appState.showInputBar()
            appState.inputBarState = .healthCard(message: message)

            // Auto-dismiss after 6 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak appState] in
                if case .healthCard = appState?.inputBarState {
                    appState?.hideInputBar()
                }
            }
        }
    }

    // MARK: - Data Gathering

    private func gatherStats() async -> HealthReport {
        let command = """
        echo "=BATTERY="; pmset -g batt 2>/dev/null; \
        echo "=DISK="; df -h / 2>/dev/null; \
        echo "=MEMORY="; vm_stat 2>/dev/null | head -8
        """

        guard let result = try? ShellRunner.run(command, timeout: 10) else {
            return HealthReport(diskFreeGB: 0, diskUsedPercent: 0, batteryPercent: nil, isCharging: false, memoryUsedGB: 0)
        }

        let output = result.output

        // Battery
        var batteryPercent: Int? = nil
        var isCharging = false
        if let range = output.range(of: "=BATTERY=") {
            let section = String(output[range.upperBound...]).components(separatedBy: "=DISK=").first ?? ""
            if let pctRange = section.range(of: #"\d+"#, options: .regularExpression),
               let beforePct = section.range(of: #"\d+%"#, options: .regularExpression) {
                let _ = pctRange // suppress warning
                batteryPercent = Int(String(section[beforePct]).replacingOccurrences(of: "%", with: ""))
            }
            isCharging = section.contains("AC Power")
        }

        // Disk
        var diskFreeGB: Double = 0
        var diskUsedPercent: Int = 0
        if let range = output.range(of: "=DISK=") {
            let section = String(output[range.upperBound...]).components(separatedBy: "=MEMORY=").first ?? ""
            let lines = section.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count >= 2 {
                let parts = lines[1].split(separator: " ").map(String.init)
                if parts.count >= 5 {
                    // parts[3] = available (e.g., "47Gi"), parts[4] = capacity (e.g., "85%")
                    diskFreeGB = parseSize(parts[3])
                    diskUsedPercent = Int(parts[4].replacingOccurrences(of: "%", with: "")) ?? 0
                }
            }
        }

        // Memory
        var memoryUsedGB: Double = 0
        if let range = output.range(of: "=MEMORY=") {
            let section = String(output[range.upperBound...])
            var activePages: UInt64 = 0
            var wiredPages: UInt64 = 0
            for line in section.components(separatedBy: "\n") {
                if line.contains("Pages active") {
                    activePages = parseVMStatPages(line)
                } else if line.contains("Pages wired") {
                    wiredPages = parseVMStatPages(line)
                }
            }
            let pageSize: UInt64 = 16384
            memoryUsedGB = Double(activePages + wiredPages) * Double(pageSize) / 1_073_741_824
        }

        return HealthReport(
            diskFreeGB: diskFreeGB,
            diskUsedPercent: diskUsedPercent,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            memoryUsedGB: memoryUsedGB
        )
    }

    private func parseSize(_ str: String) -> Double {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("Ti") {
            return (Double(cleaned.dropLast(2)) ?? 0) * 1024
        } else if cleaned.hasSuffix("Gi") {
            return Double(cleaned.dropLast(2)) ?? 0
        } else if cleaned.hasSuffix("Mi") {
            return (Double(cleaned.dropLast(2)) ?? 0) / 1024
        } else if cleaned.hasSuffix("T") {
            return (Double(cleaned.dropLast(1)) ?? 0) * 1024
        } else if cleaned.hasSuffix("G") {
            return Double(cleaned.dropLast(1)) ?? 0
        } else if cleaned.hasSuffix("M") {
            return (Double(cleaned.dropLast(1)) ?? 0) / 1024
        }
        return Double(cleaned) ?? 0
    }

    private func parseVMStatPages(_ line: String) -> UInt64 {
        let parts = line.components(separatedBy: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "") ?? "0"
        return UInt64(parts) ?? 0
    }
}

// MARK: - Health Report

struct HealthReport {
    let diskFreeGB: Double
    let diskUsedPercent: Int
    let batteryPercent: Int?
    let isCharging: Bool
    let memoryUsedGB: Double

    var isHealthy: Bool {
        diskUsedPercent < 85 && (batteryPercent ?? 100) > 20
    }

    var summaryMessage: String {
        var parts: [String] = []

        // Disk
        let freeStr = String(format: "%.0f", diskFreeGB)
        if diskUsedPercent >= 90 {
            return "Your disk is \(diskUsedPercent)% full with only \(freeStr)GB free. Want me to find large files you haven't touched in months?"
        } else if diskUsedPercent >= 85 {
            return "Heads up \u{2014} your disk is \(diskUsedPercent)% full. Want me to find large files you haven't touched in months?"
        }
        parts.append("\(freeStr)GB free")

        // Battery
        if let batt = batteryPercent {
            if batt <= 10 {
                return "Battery critically low at \(batt)% \u{2014} plug in soon!"
            } else if batt <= 20 {
                return "Battery at \(batt)% \u{2014} consider charging soon. \(freeStr)GB disk free."
            }
            let chargingStr = isCharging ? " (charging)" : ""
            parts.append("battery \(batt)%\(chargingStr)")
        }

        // Memory
        let memStr = String(format: "%.1f", memoryUsedGB)
        parts.append("\(memStr)GB RAM in use")

        return "Your Mac is running great \u{2014} \(parts.joined(separator: ", "))."
    }

    /// Just the stats, no prose — for humor mode to prepend its own flavor.
    var statsLine: String {
        var parts: [String] = []
        let freeStr = String(format: "%.0f", diskFreeGB)
        parts.append("\(freeStr)GB free")
        if let batt = batteryPercent {
            let chargingStr = isCharging ? " (charging)" : ""
            parts.append("battery \(batt)%\(chargingStr)")
        }
        let memStr = String(format: "%.1f", memoryUsedGB)
        parts.append("\(memStr)GB RAM in use")
        return parts.joined(separator: ", ")
    }
}
