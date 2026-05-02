import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedMeeting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeeting: $selectedMeeting)
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting)
            } else if appState.recorder.isRecording {
                LiveNotepadView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a meeting or start recording")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            appState.loadMeetings()
        }
    }
}

struct LiveNotepadView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Live Notes")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            if appState.liveNotes.isEmpty {
                Text("No notes yet. Jot down questions or key moments.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.liveNotes) { note in
                            HStack(alignment: .top, spacing: 10) {
                                Text(note.formattedTimestamp)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .leading)
                                Text(note.text)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                TextField("Add a note...", text: $appState.liveNoteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appState.addLiveNote() }
                Button("Add", action: appState.addLiveNote)
                    .disabled(appState.liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
