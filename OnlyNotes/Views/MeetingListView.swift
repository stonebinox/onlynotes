import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedMeeting: Meeting?
    @State private var showingError = false

    var body: some View {
        List(selection: $selectedMeeting) {
            Section {
                recordButton
            }

            if appState.processingError != nil {
                Section {
                    Button {
                        showingError = true
                    } label: {
                        Label("Transcription failed — tap for details", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Meetings") {
                ForEach(appState.meetings) { meeting in
                    NavigationLink(value: meeting) {
                        MeetingRow(meeting: meeting)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            appState.deleteMeeting(meeting)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OnlyNotes")
        .alert("Transcription Error", isPresented: $showingError, presenting: appState.processingError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if appState.isProcessing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                appState.processingError = nil
                if appState.recorder.isRecording {
                    appState.stopAndProcess { meeting in
                        selectedMeeting = meeting
                    }
                } else {
                    try? appState.startRecording()
                }
            } label: {
                HStack {
                    Image(systemName: appState.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(appState.recorder.isRecording ? .red : .accentColor)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(appState.recorder.isRecording ? "Stop Recording" : "Start Recording")
                            .fontWeight(.medium)
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

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formatDuration(meeting.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        if minutes < 1 { return "<1 min" }
        return "\(minutes) min"
    }
}
