import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Record / Stop button
            recordButton

            Divider()

            Button("Open OnlyNotes") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Divider()

            Button("Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 220)
    }

    @ViewBuilder
    private var recordButton: some View {
        if appState.isProcessing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                if appState.recorder.isRecording {
                    appState.stopAndProcess()
                } else {
                    try? appState.startRecording()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(appState.recorder.isRecording ? .red : .accentColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.recorder.isRecording ? "Stop Recording" : "Start Recording")
                            .fontWeight(.medium)
                            .font(.callout)
                        if appState.recorder.isRecording {
                            Text(formatTime(appState.recorder.elapsedTime))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
