import SwiftUI
import AVFoundation
import UserNotifications

/// General settings — merges AI Model, Agents, Voice, Notch, and Alarm into one tab.
struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedSection = 0

    var body: some View {
        VStack(spacing: 0) {
            // Section picker
            Picker("", selection: $selectedSection) {
                Text("AI Model").tag(0)
                Text("Agents").tag(1)
                Text("Voice").tag(2)
                Text("Notch").tag(3)
                Text("Alarm").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content
            switch selectedSection {
            case 0:
                AIModelSettingsTab()
            case 1:
                AgentSettingsTab()
            case 2:
                VoiceSettingsTab()
            case 3:
                NotchSettingsTab()
                    .environmentObject(appState)
            case 4:
                AlarmSettingsSection()
            default:
                AIModelSettingsTab()
            }
        }
    }
}

// MARK: - Alarm Sound Settings

struct AlarmSettingsSection: View {
    @AppStorage("alarm_sound") private var selectedSound: String = "Glass"

    private let systemSounds = [
        "Default (Critical)", "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Alarm Sound")
                    .font(.headline)
                    .padding(.top, 12)

                Text("Choose the sound that plays when an alarm goes off.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(systemSounds, id: \.self) { sound in
                    HStack {
                        Image(systemName: selectedSound == sound ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedSound == sound ? .accentColor : .secondary)
                            .font(.system(size: 16))

                        Text(sound)
                            .font(.system(size: 13))

                        Spacer()

                        Button(action: { previewSound(sound) }) {
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSound = sound
                        previewSound(sound)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(selectedSound == sound ? Color.accentColor.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func previewSound(_ name: String) {
        if name == "Default (Critical)" {
            NSSound(named: "Glass")?.play()
        } else {
            NSSound(named: NSSound.Name(name))?.play()
        }
    }
}

/// Helper to get the user's chosen alarm sound as a UNNotificationSound.
enum AlarmSoundPreference {
    static var notificationSound: UNNotificationSound {
        let chosen = UserDefaults.standard.string(forKey: "alarm_sound") ?? "Glass"
        if chosen == "Default (Critical)" {
            return .defaultCritical
        }
        // System sounds are at /System/Library/Sounds/<name>.aiff
        return UNNotificationSound(named: UNNotificationSoundName("\(chosen).aiff"))
    }
}
