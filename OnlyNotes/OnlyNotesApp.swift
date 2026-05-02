import SwiftUI
import UserNotifications

@main
struct OnlyNotesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("OnlyNotes", systemImage: "mic.circle.fill") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("OnlyNotes", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 540)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
