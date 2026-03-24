import Cocoa
import UserNotifications
import Speech
import AVFoundation

class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var accessibilityGranted = false
    @Published var notificationsGranted = false
    @Published var eventTapAvailable = false
    @Published var appleEventsGranted = false
    @Published var microphoneGranted = false
    @Published var speechRecognitionGranted = false

    private init() {}

    func checkAll() {
        refreshAccessibility()
        refreshEventTap()
        refreshAppleEvents()
        refreshMicrophone()
        refreshSpeechRecognition()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Re-check accessibility by calling the system API fresh.
    func refreshAccessibility() {
        // AXIsProcessTrusted() can cache. Force a fresh check by calling with options.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Keep rechecking since user needs to interact with System Settings
        for delay in [2.0, 4.0, 8.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAccessibility()
                self?.refreshEventTap()
            }
        }
    }

    /// Check if we can create a CGEvent tap (requires Input Monitoring or Accessibility).
    func refreshEventTap() {
        let accessible = CGPreflightListenEventAccess()
        eventTapAvailable = accessible
    }

    func requestEventTapAccess() {
        // CGRequestListenEventAccess() is unreliable on newer macOS — open the pane directly
        openInputMonitoringSettings()
        for delay in [2.0, 4.0, 8.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshEventTap()
            }
        }
    }

    func requestNotifications() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run {
                    notificationsGranted = granted
                }
            } catch {
                await MainActor.run {
                    notificationsGranted = false
                }
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    /// Test whether we have Apple Events / Automation permission by running a harmless script.
    func refreshAppleEvents() {
        let result = AppleScriptRunner.run("tell application \"System Events\" to get name of first process")
        appleEventsGranted = result != nil
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    // MARK: - Microphone

    func refreshMicrophone() {
        if #available(macOS 14.0, *) {
            microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            microphoneGranted = true
        }
    }

    func requestMicrophone() {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneGranted = granted
                }
            }
        }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: - Speech Recognition

    func refreshSpeechRecognition() {
        speechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.speechRecognitionGranted = status == .authorized
            }
        }
    }

    func openSpeechRecognitionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
    }
}
