import SwiftUI

struct NoteListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedNote: Note?
    @State private var showingError = false

    var body: some View {
        List(selection: $selectedNote) {
            Section {
                recordButton
            }

            if appState.recorder.isRecording {
                Section {
                    liveNotepadView
                }
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

            Section("Notes") {
                ForEach(appState.notes) { note in
                    NavigationLink(value: note) {
                        NoteRow(note: note)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            if selectedNote?.id == note.id {
                                selectedNote = nil
                            }
                            appState.deleteNote(note)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OnlyNotes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNewNote) {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
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
                    appState.stopAndProcess(onNoteSaved: { note in
                        selectedNote = note
                    })
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

    private var liveNotepadView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Recent notes preview (last 3, newest first)
            ForEach(appState.liveNotes.suffix(3).reversed()) { note in
                HStack(alignment: .top, spacing: 6) {
                    Text(note.formattedTimestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .leading)
                    Text(note.text)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            // Note entry
            HStack(spacing: 4) {
                TextField("Note...", text: $appState.liveNoteDraft)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .onSubmit { appState.addLiveNote() }
                Button(action: { appState.addLiveNote() }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(appState.liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 4)
    }

    private func createNewNote() {
        let newNote = Note(title: "", body: "", createdAt: Date(), updatedAt: Date())
        appState.saveNote(newNote)
        appState.loadNotes()
        selectedNote = newNote
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: note.isMeetingNote ? "mic.fill" : "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(note.title.isEmpty ? "Untitled Note" : note.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            HStack {
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                if note.isMeetingNote, let duration = note.meetingAttachment?.duration {
                    Text("·")
                    Text(formatDuration(duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    let visibleTags = Array(note.tags.prefix(3))
                    let extraCount = note.tags.count - visibleTags.count
                    ForEach(visibleTags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if extraCount > 0 {
                        Text("+\(extraCount) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        if minutes < 1 { return "<1 min" }
        return "\(minutes) min"
    }
}
