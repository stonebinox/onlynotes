import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .fontWeight(.medium)
            } else {
                Label("OnlyNotes", systemImage: "note.text")
                    .fontWeight(.medium)
            }

            Divider()

            Button("Open OnlyNotes") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 200)
    }
}
