import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            AIModelSettingsTab()
                .tabItem { Label("AI Model", systemImage: "cpu") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "mic.circle") }
            NotchSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }
}
