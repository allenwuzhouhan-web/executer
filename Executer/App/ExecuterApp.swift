import SwiftUI

@main
struct ExecuterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Executer", systemImage: "sparkle") {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        }
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button("Show Command Bar") {
            appState.toggleInputBar()
        }
        .keyboardShortcut(.space, modifiers: [.command, .shift])

        Divider()

        Button("Command History...") {
            appState.showHistory = true
        }

        Divider()

        SettingsLink {
            Text("Settings...")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Executer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
