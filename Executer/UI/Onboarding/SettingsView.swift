import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            AIModelSettingsTab()
                .tabItem { Label("AI Model", systemImage: "cpu") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            LearningSettingsTab()
                .tabItem { Label("Learning", systemImage: "brain") }
            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "mic.circle") }
            LanguageSettingsTab()
                .tabItem { Label("Language", systemImage: "globe") }
            NotchSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            UpdateSettingsTab()
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }
}
