import SwiftUI

struct NoteListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedNote: Note?
    @State private var showingError = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        List(selection: $selectedNote) {
            Section {
                recordButtonView
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
                        noteRow(for: note)
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

    // MARK: - Note Row

    private func noteRow(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Title row
            HStack(spacing: Spacing.sm) {
                Image(systemName: note.isMeetingNote ? "waveform" : "note.text")
                    .font(.caption2)
                    .foregroundStyle(note.isMeetingNote ? Color.onAccent : Color.onMutedInk)
                    .frame(width: 14)
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.onHeadline)
                    .foregroundStyle(Color.onInk)
                    .lineLimit(1)
            }

            // Date + meta
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.onMeta)
                .foregroundStyle(Color.onFaintInk)

            // Snippet
            let snippet = note.body.isEmpty
                ? (note.meetingAttachment?.summary ?? "")
                : note.body
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.onCaption)
                    .foregroundStyle(Color.onMutedInk)
                    .lineLimit(2)
            }

            // Tag chips
            if !note.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(note.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.onAccent.opacity(0.12), in: Capsule())
                        }
                        if note.tags.count > 3 {
                            Text("+\(note.tags.count - 3)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.onFaintInk)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    // MARK: - Record Button

    private var recordButtonView: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                // Pulse ring — only animates when recording
                if appState.recorder.isRecording {
                    Circle()
                        .stroke(Color.onRecordActive.opacity(0.3), lineWidth: 2)
                        .frame(width: 52, height: 52)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                pulseScale = 1.35
                                pulseOpacity = 0.0
                            }
                        }
                        .onDisappear {
                            pulseScale = 1.0
                            pulseOpacity = 0.6
                        }
                }

                // Main button
                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(appState.recorder.isRecording
                                  ? Color.onRecordActive
                                  : Color.onRaised)
                            .frame(width: 44, height: 44)
                            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)

                        Image(systemName: appState.recorder.isRecording
                              ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appState.recorder.isRecording
                                             ? .white : Color.onMutedInk)
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                if appState.isProcessing {
                    Text("Transcribing…")
                        .font(.onHeadline)
                        .foregroundStyle(Color.onInk)
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.onAccent)
                } else if appState.recorder.isRecording {
                    Text("Recording")
                        .font(.onHeadline)
                        .foregroundStyle(Color.onRecordActive)
                    Text(formatTime(appState.recorder.elapsedTime))
                        .font(.onMeta)
                        .foregroundStyle(Color.onMutedInk)
                        .monospacedDigit()
                } else {
                    Text("New Recording")
                        .font(.onHeadline)
                        .foregroundStyle(Color.onInk)
                    Text("Tap mic to start")
                        .font(.onCaption)
                        .foregroundStyle(Color.onFaintInk)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func toggleRecording() {
        appState.processingError = nil
        if appState.recorder.isRecording {
            appState.stopAndProcess(onNoteSaved: { note in
                selectedNote = note
            })
        } else {
            try? appState.startRecording()
        }
    }

    // MARK: - Live Notepad

    private var liveNotepadView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Recent notes preview (last 3, newest first)
            ForEach(appState.liveNotes.suffix(3).reversed()) { note in
                HStack(alignment: .top, spacing: 6) {
                    Text(note.formattedTimestamp)
                        .font(.caption2)
                        .foregroundStyle(Color.onMutedInk)
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
                        .foregroundStyle(Color.onAccent)
                }
                .buttonStyle(.plain)
                .disabled(appState.liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(6)
            .background(Color.onSeparator.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

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

