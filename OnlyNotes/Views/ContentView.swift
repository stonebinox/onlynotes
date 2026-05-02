import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedNote: Note?

    var body: some View {
        NavigationSplitView {
            NoteListView(selectedNote: $selectedNote)
        } detail: {
            if let note = selectedNote {
                if note.isMeetingNote {
                    MeetingDetailView(note: note)
                        .id(note.id)
                } else {
                    NoteEditorView(note: note)
                        .id(note.id)
                }
            } else if appState.recorder.isRecording {
                LiveNotepadView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a note or start recording")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { appState.loadNotes() }
    }
}

// MARK: - Note Editor View

struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @State var note: Note
    @State private var tagDraft: String = ""
    @State private var saveTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            TextField("Title", text: $note.title)
                .font(.title)
                .fontWeight(.semibold)
                .textFieldStyle(.plain)
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)
                .onChange(of: note.title) { _, _ in scheduleSave() }

            // Tags
            tagEditorView
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            // Body
            TextEditor(text: $note.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .onChange(of: note.body) { _, _ in scheduleSave() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            saveTimer?.invalidate()
            saveTimer = nil
        }
    }

    private var tagEditorView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(note.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag).font(.caption)
                        Button(action: { removeTag(tag) }) {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
                TextField("Add tag...", text: $tagDraft)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .frame(width: 80)
                    .onSubmit { commitTag() }
                    .onChange(of: tagDraft) { _, new in
                        if new.hasSuffix(",") { tagDraft = String(new.dropLast()); commitTag() }
                    }
            }
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        let capturedID = note.id
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [self] _ in
            guard note.id == capturedID else { return }
            var updated = note
            updated.updatedAt = Date()
            DispatchQueue.main.async {
                appState.saveNote(updated)
            }
        }
    }

    private func commitTag() {
        let trimmed = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { tagDraft = ""; return }
        var updated = note
        updated.setTags(note.tags + [trimmed])
        note = updated
        appState.saveNote(updated)
        tagDraft = ""
    }

    private func removeTag(_ tag: String) {
        var updated = note
        updated.setTags(note.tags.filter { $0 != tag })
        note = updated
        appState.saveNote(updated)
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
