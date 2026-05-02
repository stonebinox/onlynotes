import SwiftUI
import UserNotifications

@main
struct OnlyNotesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("OnlyNotes", systemImage: "mic.circle.fill") {
            MenuBarView()
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredColorScheme)
        }
        .menuBarExtraStyle(.window)

        Window("OnlyNotes", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 540)
                .preferredColorScheme(appState.preferredColorScheme)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
