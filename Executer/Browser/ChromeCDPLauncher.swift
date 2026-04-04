import Foundation
import AppKit

/// Ensures Chrome is running with CDP (Chrome DevTools Protocol) enabled.
/// Used by IXL and other tasks that need to control the user's real browser.
struct ChromeCDPLauncher {
    static let port = 9222
    static let cdpURL = "http://localhost:\(port)"
    static let chromeBundleID = "com.google.Chrome"

    /// Ensure Chrome is running with CDP on port 9222. Returns true on success.
    static func ensureChromeWithCDP() async -> Bool {
        // 1. If CDP is already reachable, we're done
        if await isCDPReachable() { return true }

        // 2. Check if Chrome is installed
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) else {
            print("[ChromeCDP] Chrome not installed")
            return false
        }

        // 3. If Chrome is running without CDP, terminate and relaunch
        let runningChromes = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == chromeBundleID
        }
        if !runningChromes.isEmpty {
            print("[ChromeCDP] Chrome running without CDP — restarting with --remote-debugging-port=\(port)")
            for app in runningChromes {
                app.terminate()
            }
            // Wait for Chrome to fully exit
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                let still = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == chromeBundleID
                }
                if still.isEmpty { break }
            }
        }

        // 4. Launch Chrome with CDP flag
        print("[ChromeCDP] Launching Chrome with --remote-debugging-port=\(port)")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--remote-debugging-port=\(port)"]

        do {
            try await NSWorkspace.shared.openApplication(at: chromeURL, configuration: config)
        } catch {
            print("[ChromeCDP] Launch failed: \(error)")
            return false
        }

        // 5. Wait for CDP to become reachable (up to 10 seconds)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            if await isCDPReachable() {
                print("[ChromeCDP] Chrome ready with CDP on port \(port)")
                return true
            }
        }

        print("[ChromeCDP] Timeout waiting for CDP")
        return false
    }

    /// Check if CDP is reachable by probing the /json/version endpoint.
    private static func isCDPReachable() async -> Bool {
        guard let url = URL(string: "\(cdpURL)/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
