import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            LearningSettingsTab()
                .tabItem { Label("Learning", systemImage: "brain") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            SecuritySettingsTab()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            LanguageSettingsTab()
                .tabItem { Label("Language & Region", systemImage: "globe") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 620)
    }
}
