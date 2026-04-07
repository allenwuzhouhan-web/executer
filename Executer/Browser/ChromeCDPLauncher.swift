import Foundation
import AppKit

/// Ensures a Chromium-based browser is running with CDP enabled.
/// Supports Chrome, Edge, Arc, and Brave — tries in order of preference.
struct ChromeCDPLauncher {
    static let port = 9222
    static let cdpURL = "http://localhost:\(port)"

    /// Supported Chromium-based browsers, in preference order.
    private static let supportedBrowsers: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Arc", "company.thebrowser.Browser"),
        ("Brave Browser", "com.brave.Browser"),
        ("Chromium", "org.chromium.Chromium"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
    ]

    /// Ensure a Chromium browser is running with CDP on port 9222. Returns true on success.
    static func ensureChromeWithCDP() async -> Bool {
        // 1. If CDP is already reachable, we're done
        if await isCDPReachable() {
            print("[ChromeCDP] CDP already active on port \(port)")
            return true
        }

        // 2. Find an installed Chromium browser
        guard let browser = findInstalledBrowser() else {
            print("[ChromeCDP] No supported Chromium browser installed (Chrome, Edge, Arc, Brave)")
            return false
        }

        // 3. If the browser is running without CDP, terminate and relaunch
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == browser.bundleID
        }
        if !running.isEmpty {
            print("[ChromeCDP] \(browser.name) running without CDP — restarting with --remote-debugging-port=\(port)")
            for app in running {
                app.terminate()
            }
            // Wait for full exit
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let still = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == browser.bundleID
                }
                if still.isEmpty { break }
            }
        }

        // 4. Launch with CDP flag
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            return false
        }
        print("[ChromeCDP] Launching \(browser.name) with --remote-debugging-port=\(port)")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--remote-debugging-port=\(port)"]

        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            print("[ChromeCDP] Launch failed: \(error)")
            return false
        }

        // 5. Wait for CDP to become reachable (up to 10 seconds)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isCDPReachable() {
                print("[ChromeCDP] \(browser.name) ready with CDP on port \(port)")
                return true
            }
        }

        print("[ChromeCDP] Timeout waiting for CDP")
        return false
    }

    /// Find the first installed Chromium browser.
    private static func findInstalledBrowser() -> (name: String, bundleID: String)? {
        for browser in supportedBrowsers {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil {
                return browser
            }
        }
        return nil
    }

    /// Name of the installed browser (for UI messages).
    static var installedBrowserName: String {
        findInstalledBrowser()?.name ?? "Chrome"
    }

    /// Check if CDP is reachable by probing the /json/version endpoint.
    static func isCDPReachable() async -> Bool {
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
