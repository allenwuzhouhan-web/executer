import Foundation
import Cocoa

// MARK: - Step 1: System Info Tool

struct GetSystemInfoTool: ToolDefinition {
    let name = "get_system_info"
    let description = "Get comprehensive system information: battery, disk, memory, CPU, Wi-Fi, display resolutions, and uptime"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let command = """
        echo "=BATTERY="; pmset -g batt 2>/dev/null; \
        echo "=DISK="; df -h / 2>/dev/null; \
        echo "=MEMORY="; vm_stat 2>/dev/null | head -8; \
        echo "=CPU="; sysctl -n machdep.cpu.brand_string 2>/dev/null; \
        echo "=UPTIME="; uptime 2>/dev/null; \
        echo "=WIFI="; networksetup -getairportnetwork en0 2>/dev/null
        """
        let result = try ShellRunner.run(command, timeout: 10)

        var lines: [String] = ["System Information:"]

        // Battery
        if let range = result.output.range(of: "=BATTERY=") {
            let batterySection = String(result.output[range.upperBound...])
                .components(separatedBy: "=DISK=").first ?? ""
            if let pctRange = batterySection.range(of: #"\d+%"#, options: .regularExpression) {
                let pct = String(batterySection[pctRange])
                let charging = batterySection.contains("AC Power") ? " (charging)" : " (battery)"
                lines.append("- Battery: \(pct)\(charging)")
            }
        }

        // Disk
        if let range = result.output.range(of: "=DISK=") {
            let diskSection = String(result.output[range.upperBound...])
                .components(separatedBy: "=MEMORY=").first ?? ""
            let diskLines = diskSection.components(separatedBy: "\n").filter { !$0.isEmpty }
            if diskLines.count >= 2 {
                let parts = diskLines[1].split(separator: " ").map(String.init)
                if parts.count >= 5 {
                    lines.append("- Disk: \(parts[2]) used of \(parts[1]) (\(parts[4]) capacity)")
                }
            }
        }

        // Memory
        if let range = result.output.range(of: "=MEMORY=") {
            let memSection = String(result.output[range.upperBound...])
                .components(separatedBy: "=CPU=").first ?? ""
            // Parse vm_stat pages
            var freePages: UInt64 = 0
            var activePages: UInt64 = 0
            var wiredPages: UInt64 = 0
            for line in memSection.components(separatedBy: "\n") {
                if line.contains("Pages free") {
                    freePages = parseVMStatPages(line)
                } else if line.contains("Pages active") {
                    activePages = parseVMStatPages(line)
                } else if line.contains("Pages wired") {
                    wiredPages = parseVMStatPages(line)
                }
            }
            let pageSize: UInt64 = 16384 // 16KB on Apple Silicon
            let usedGB = Double(activePages + wiredPages) * Double(pageSize) / 1_073_741_824
            let freeGB = Double(freePages) * Double(pageSize) / 1_073_741_824
            lines.append("- Memory: \(String(format: "%.1f", usedGB)) GB used, \(String(format: "%.1f", freeGB)) GB free")
        }

        // CPU
        if let range = result.output.range(of: "=CPU=") {
            let cpuSection = String(result.output[range.upperBound...])
                .components(separatedBy: "=UPTIME=").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cpuSection.isEmpty {
                lines.append("- CPU: \(cpuSection)")
            }
        }

        // Uptime
        if let range = result.output.range(of: "=UPTIME=") {
            let uptimeSection = String(result.output[range.upperBound...])
                .components(separatedBy: "=WIFI=").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let upRange = uptimeSection.range(of: "up ") {
                let upStr = String(uptimeSection[upRange.upperBound...])
                    .components(separatedBy: ",").prefix(2).joined(separator: ",")
                lines.append("- Uptime: \(upStr.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Wi-Fi
        if let range = result.output.range(of: "=WIFI=") {
            let wifiSection = String(result.output[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if wifiSection.contains("Current Wi-Fi Network:") {
                let ssid = wifiSection.replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("- Wi-Fi: \(ssid)")
            } else {
                lines.append("- Wi-Fi: Not connected")
            }
        }

        // Displays
        let displayCount = NSScreen.screens.count
        let resolutions = NSScreen.screens.map { screen -> String in
            let size = screen.frame.size
            let scale = screen.backingScaleFactor
            return "\(Int(size.width * scale))x\(Int(size.height * scale))"
        }
        lines.append("- Displays: \(displayCount) (\(resolutions.joined(separator: ", ")))")

        return lines.joined(separator: "\n")
    }

    private func parseVMStatPages(_ line: String) -> UInt64 {
        let parts = line.components(separatedBy: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "") ?? "0"
        return UInt64(parts) ?? 0
    }
}
