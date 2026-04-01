import Foundation
import AppKit

/// One-click auto-updater that checks GitHub releases for new versions.
/// Downloads the latest DMG, mounts it, replaces the running app, and relaunches.
/// API keys (Keychain) and permissions (Accessibility, etc.) persist automatically.
class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let repo = "allenwuzhouhan-web/executer"
    private let githubAPI = "https://api.github.com/repos"

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var updateProgress: Double = 0
    @Published var updateStatus: String = ""

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private init() {}

    // MARK: - Check for Updates

    /// Checks GitHub releases API for a newer version. Safe to call on launch.
    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { Task { @MainActor in self.isChecking = false } }

            guard let url = URL(string: "\(githubAPI)/\(repo)/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await PinnedURLSession.shared.session.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return
            }

            // Find DMG asset
            var dmgURL: String?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let browserURL = asset["browser_download_url"] as? String {
                        dmgURL = browserURL
                        break
                    }
                }
            }

            // Compare versions
            let latest = tagName.replacingOccurrences(of: "v", with: "")
            let current = currentVersion

            await MainActor.run {
                self.latestVersion = latest
                self.downloadURL = dmgURL
                self.updateAvailable = latest != current && dmgURL != nil
                if self.updateAvailable {
                    print("[Updater] Update available: \(current) → \(latest)")
                }
            }
        }
    }

    // MARK: - Perform Update

    /// Downloads the DMG, extracts the .app, replaces current app, and relaunches.
    func performUpdate() {
        guard let urlString = downloadURL, let url = URL(string: urlString) else { return }
        guard !isUpdating else { return }

        isUpdating = true
        updateStatus = "Downloading update..."
        updateProgress = 0

        Task {
            do {
                // Step 1: Download DMG
                let (tempURL, _) = try await downloadWithProgress(url)
                await MainActor.run { self.updateStatus = "Mounting disk image..." ; self.updateProgress = 0.5 }

                // Step 2: Mount DMG
                let mountPoint = try await mountDMG(tempURL)
                defer { unmountDMG(mountPoint) }

                await MainActor.run { self.updateStatus = "Installing update..." ; self.updateProgress = 0.7 }

                // Step 3: Find .app in mounted DMG
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(atPath: mountPoint)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw UpdateError.noAppInDMG
                }
                let sourceApp = "\(mountPoint)/\(appName)"

                // Step 4: Replace current app
                let currentAppPath = Bundle.main.bundlePath
                let backupPath = currentAppPath + ".backup"

                // Create backup
                if fm.fileExists(atPath: backupPath) {
                    try fm.removeItem(atPath: backupPath)
                }
                try fm.moveItem(atPath: currentAppPath, toPath: backupPath)

                do {
                    try fm.copyItem(atPath: sourceApp, toPath: currentAppPath)
                } catch {
                    // Restore backup on failure
                    try? fm.moveItem(atPath: backupPath, toPath: currentAppPath)
                    throw UpdateError.installFailed(error.localizedDescription)
                }

                // Remove backup
                try? fm.removeItem(atPath: backupPath)

                // Clean up downloaded DMG
                try? fm.removeItem(at: tempURL)

                await MainActor.run { self.updateStatus = "Relaunching..." ; self.updateProgress = 1.0 }

                // Step 5: Relaunch
                try await Task.sleep(nanoseconds: 500_000_000)
                relaunch()

            } catch {
                await MainActor.run {
                    self.isUpdating = false
                    self.updateStatus = "Update failed: \(error.localizedDescription)"
                    print("[Updater] Failed: \(error)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func downloadWithProgress(_ url: URL) async throws -> (URL, URLResponse) {
        let (tempURL, response) = try await PinnedURLSession.shared.session.download(from: url)
        // Move to a known location (download() returns a temp that gets cleaned up)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Executer-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return (dest, response)
    }

    private func mountDMG(_ dmgPath: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgPath.path, "-nobrowse", "-quiet", "-mountpoint", "/tmp/ExecuterUpdate"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "mount failed"
            throw UpdateError.mountFailed(msg)
        }
        return "/tmp/ExecuterUpdate"
    }

    private func unmountDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet", "-force"]
        try? process.run()
        process.waitUntilExit()
    }

    private func relaunch() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    enum UpdateError: LocalizedError {
        case noAppInDMG
        case mountFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAppInDMG: return "No app found in the disk image."
            case .mountFailed(let msg): return "Could not mount DMG: \(msg)"
            case .installFailed(let msg): return "Install failed: \(msg)"
            }
        }
    }
}
