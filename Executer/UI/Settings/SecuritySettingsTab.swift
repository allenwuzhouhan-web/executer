import SwiftUI

/// Security dashboard — shows integrity status, environment posture, runtime protection, and audit log summary.
struct SecuritySettingsTab: View {
    @State private var integrityStatus: String = "Checking..."
    @State private var codeSigningStatus: String = "Checking..."
    @State private var environmentStatus: String = "Checking..."
    @State private var runtimeStatus: String = "Checking..."
    @State private var pinningStatus: String = "Checking..."
    @State private var auditEntryCount: Int = 0
    @State private var auditDiskUsage: String = "..."
    @State private var isRunningCheck = false
    @State private var lastCheckTime: Date?
    @State private var exportedPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "shield.checkered")
                        .font(.title)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Security Dashboard")
                            .font(.title2.bold())
                        Text("Build: \(AppModel.buildEnvironment.rawValue) | Model: \(AppModel.modelNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Integrity Status
                securitySection(title: "Integrity Verification", icon: "checkmark.shield") {
                    statusRow("Integrity Checks", value: integrityStatus)
                    statusRow("Code Signing", value: codeSigningStatus)
                }

                // Environment
                securitySection(title: "Environment", icon: "desktopcomputer") {
                    Text(environmentStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Runtime Protection
                securitySection(title: "Runtime Protection", icon: "shield.lefthalf.filled") {
                    statusRow("Runtime Shield", value: runtimeStatus)
                    statusRow("Certificate Pinning", value: pinningStatus)
                    if let time = lastCheckTime {
                        statusRow("Last Check", value: timeAgo(time))
                    }
                }

                // Audit Log
                securitySection(title: "Audit Log", icon: "doc.text.magnifyingglass") {
                    statusRow("Session Entries", value: "\(auditEntryCount)")
                    statusRow("Disk Usage", value: auditDiskUsage)
                }

                Divider()

                // Actions
                HStack(spacing: 12) {
                    Button {
                        runIntegrityCheck()
                    } label: {
                        Label("Run Integrity Check", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(isRunningCheck)

                    Button {
                        exportAuditLog()
                    } label: {
                        Label("Export Audit Log", systemImage: "square.and.arrow.up")
                    }

                    if AppModel.buildEnvironment == .release {
                        Button {
                            verifyManifest()
                        } label: {
                            Label("Verify Against GitHub", systemImage: "globe")
                        }
                        .disabled(isRunningCheck)
                    }
                }
                .buttonStyle(.bordered)

                if let path = exportedPath {
                    Text("Exported to: \(path)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear { refreshAll() }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func securitySection(title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.contains("INVALID") || value.contains("FAILED") || value.contains("DISABLED") ? .red : .primary)
        }
        .font(.caption)
    }

    // MARK: - Refresh

    private func refreshAll() {
        // Integrity
        let env = AppModel.buildEnvironment
        integrityStatus = env == .debug ? "Skipped (debug)" : "Passed"

        // Code signing
        codeSigningStatus = CodeSigningVerifier.statusSummary()

        // Environment
        environmentStatus = EnvironmentIntegrity.statusSummary()

        // Runtime
        runtimeStatus = RuntimeShield.statusSummary()

        // Pinning
        pinningStatus = PinnedURLSession.statusSummary()

        // Audit log
        Task {
            let count = await AuditLog.shared.entryCount
            let usage = await AuditLog.shared.diskUsage()
            await MainActor.run {
                auditEntryCount = count
                auditDiskUsage = ByteCountFormatter.string(fromByteCount: usage, countStyle: .file)
            }
        }

        lastCheckTime = Date()
    }

    // MARK: - Actions

    private func runIntegrityCheck() {
        isRunningCheck = true
        Task {
            let allowed = await RateLimiter.shared.check(operation: "integrity_manual")
            guard allowed else {
                await MainActor.run {
                    integrityStatus = "Rate limited — try again later"
                    isRunningCheck = false
                }
                return
            }
            await RateLimiter.shared.recordAttempt(operation: "integrity_manual")

            let result = IntegrityChecker.verify()
            await MainActor.run {
                switch result {
                case .passed:
                    integrityStatus = "All checks passed"
                case .failed(let reason):
                    integrityStatus = "FAILED: \(reason)"
                }
                lastCheckTime = Date()
                isRunningCheck = false
            }
        }
    }

    private func verifyManifest() {
        isRunningCheck = true
        Task {
            let result = await ManifestVerifier.shared.verifyAgainstGitHub()
            await MainActor.run {
                switch result {
                case .matched:
                    integrityStatus = "Manifest verified — binary matches official release"
                case .mismatch(let reason):
                    integrityStatus = "MANIFEST MISMATCH: \(reason)"
                case .signatureInvalid:
                    integrityStatus = "MANIFEST SIGNATURE INVALID"
                case .networkUnavailable:
                    integrityStatus = "Cannot reach GitHub — check network"
                case .noManifest:
                    integrityStatus = "No manifest available for this version"
                }
                isRunningCheck = false
            }
        }
    }

    private func exportAuditLog() {
        Task {
            let entries = await AuditLog.shared.loadHistory(days: 7)
            let currentEntries = await AuditLog.shared.recentEntries(count: 1000)
            let allEntries = entries + currentEntries

            guard !allEntries.isEmpty else {
                await MainActor.run { exportedPath = "No audit entries to export" }
                return
            }

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(allEntries)

                let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                let filename = "executer_audit_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
                let fileURL = dir.appendingPathComponent(filename)
                try data.write(to: fileURL, options: .atomic)

                await MainActor.run { exportedPath = "~/Desktop/\(filename)" }
            } catch {
                await MainActor.run { exportedPath = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Helpers

    private func timeAgo(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }
}
