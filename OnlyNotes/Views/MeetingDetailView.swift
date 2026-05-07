import SwiftUI
import AVFoundation

struct MeetingDetailView: View {
    @EnvironmentObject var appState: AppState
    @State var note: Note
    @State private var selectedTab = 0
    @State private var isRegenerating = false
    @State private var editingNoteID: UUID? = nil
    @State private var editingNoteDraft: String = ""
    @State private var tagDraft: String = ""

    private var attachment: MeetingAttachment? { note.meetingAttachment }

    var body: some View {
        if attachment == nil {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.onFaintInk)
                Text("No meeting data available")
                    .foregroundStyle(Color.onMutedInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text(note.title.isEmpty ? "Untitled Note" : note.title)
                    .font(.onTitle)
                    .foregroundStyle(Color.onInk)

                HStack(spacing: 16) {
                    Label(note.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label(formatDuration(attachment?.duration ?? 0), systemImage: "clock")
                    if !(attachment?.segments.isEmpty ?? true) {
                        Label("\(speakerCount) speakers", systemImage: "person.2")
                    }
                    Spacer()
                    Button(action: exportNote) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.onMeta)
                .foregroundStyle(Color.onFaintInk)

                tagEditor

                if let path = attachment?.audioFilePath {
                    AudioPlayerBar(url: URL(fileURLWithPath: path))
                }
            }
            .padding()
            .background(Color.onPanel)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.onSeparator)
                    .frame(height: 1)
            }

            EditorialTabBar(
                tabs: ["Summary", "Action Items", "Speakers", "Transcript", "Chat", "Notes"],
                selection: $selectedTab
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case 0: summaryView
                    case 1: actionItemsView
                    case 2: speakersView
                    case 3: transcriptView
                    case 4: chatView
                    case 5: notesTab
                    default: EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        } // else
    }

    // MARK: - Tag Editor

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(note.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag)
                                .font(.caption)
                            Button(action: { removeTag(tag) }) {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.onSeparator.opacity(0.5), in: Capsule())
                    }

                    TextField("Add tag...", text: $tagDraft)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .frame(width: 80)
                        .onSubmit { commitTag() }
                        .onChange(of: tagDraft) { _, new in
                            if new.hasSuffix(",") {
                                tagDraft = String(new.dropLast())
                                commitTag()
                            }
                        }
                }
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

    // MARK: - Subviews

    @ViewBuilder
    private var summaryView: some View {
        if isRegenerating {
            HStack { ProgressView().controlSize(.small); Text("Regenerating summary…").foregroundStyle(.secondary) }
        } else if (attachment?.summary ?? "").isEmpty {
            Text("No summary available").foregroundStyle(.secondary).italic()
        } else {
            Text(attachment?.summary ?? "").lineSpacing(4)
        }
    }

    @ViewBuilder
    private var actionItemsView: some View {
        if (attachment?.actionItems ?? []).isEmpty {
            Text("No action items").foregroundStyle(.secondary).italic()
        } else {
            ForEach(attachment?.actionItems ?? [], id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    Text(item)
                }
            }
        }
    }

    @ViewBuilder
    private var speakersView: some View {
        if (attachment?.segments ?? []).isEmpty {
            Text("No speaker data available").foregroundStyle(.secondary).italic()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename speakers detected in this meeting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(uniqueSpeakerTags, id: \.self) { tag in
                    SpeakerRenameRow(
                        tag: tag,
                        name: Binding(
                            get: { note.meetingAttachment?.speakers[String(tag)] ?? "" },
                            set: { newName in
                                var updated = note
                                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    updated.meetingAttachment?.speakers.removeValue(forKey: String(tag))
                                } else {
                                    updated.meetingAttachment?.speakers[String(tag)] = newName
                                }
                                note = updated
                                // Disk save is deferred to onCommit
                            }
                        ),
                        onCommit: {
                            var updated = note
                            let trimmed = (updated.meetingAttachment?.speakers[String(tag)] ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                updated.meetingAttachment?.speakers.removeValue(forKey: String(tag))
                            } else {
                                updated.meetingAttachment?.speakers[String(tag)] = trimmed
                            }
                            note = updated
                            appState.saveNote(updated)
                        }
                    )
                }

                if !(attachment?.speakers ?? [:]).isEmpty {
                    Button("Regenerate Summary with Speaker Names") {
                        regenerateSummary()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRegenerating)
                }
            }
            .onDisappear {
                appState.saveNote(note)
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if (attachment?.segments ?? []).isEmpty {
            Text("No transcript available").foregroundStyle(.secondary).italic()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(attachment?.segments ?? []) { segment in
                    TranscriptSegmentRow(segment: segment, speakers: attachment?.speakers ?? [:])
                }
            }
        }
    }

    @ViewBuilder
    private var chatView: some View {
        MeetingChatView(note: $note)
    }

    private var notesTab: some View {
        Group {
            if (attachment?.notes ?? []).isEmpty {
                Text("No notes were captured during this recording.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(attachment?.notes ?? []) { meetingNote in
                            noteRow(for: meetingNote)
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteRow(for meetingNote: MeetingNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(meetingNote.formattedTimestamp)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
                .padding(.top, editingNoteID == meetingNote.id ? 6 : 0)

            if editingNoteID == meetingNote.id {
                // Editing mode
                TextField("Note", text: $editingNoteDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .onSubmit { commitNoteEdit(id: meetingNote.id) }

                Button(action: { commitNoteEdit(id: meetingNote.id) }) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(editingNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: { cancelNoteEdit() }) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                // Display mode
                Text(meetingNote.text)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { beginNoteEdit(meetingNote) }

                HStack(spacing: 8) {
                    Button(action: { beginNoteEdit(meetingNote) }) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: { deleteMeetingNote(id: meetingNote.id) }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Edit") { beginNoteEdit(meetingNote) }
            Divider()
            Button("Delete", role: .destructive) { deleteMeetingNote(id: meetingNote.id) }
        }
    }

    private func beginNoteEdit(_ meetingNote: MeetingNote) {
        editingNoteID = meetingNote.id
        editingNoteDraft = meetingNote.text
    }

    private func cancelNoteEdit() {
        editingNoteID = nil
        editingNoteDraft = ""
    }

    private func commitNoteEdit(id: UUID) {
        let trimmed = editingNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelNoteEdit()
            return
        }
        var updated = note
        if let idx = updated.meetingAttachment?.notes.firstIndex(where: { $0.id == id }) {
            updated.meetingAttachment?.notes[idx].text = trimmed
        }
        note = updated
        appState.saveNote(updated)
        editingNoteID = nil
        editingNoteDraft = ""
    }

    private func deleteMeetingNote(id: UUID) {
        var updated = note
        updated.meetingAttachment?.notes.removeAll { $0.id == id }
        note = updated
        appState.saveNote(updated)
        if editingNoteID == id {
            editingNoteID = nil
            editingNoteDraft = ""
        }
    }

    // MARK: - Helpers

    private var uniqueSpeakerTags: [Int] {
        Array(Set((attachment?.segments ?? []).map(\.speakerTag))).sorted()
    }

    private var speakerCount: Int {
        uniqueSpeakerTags.count
    }

    private func regenerateSummary() {
        isRegenerating = true
        Task {
            do {
                let service = OpenAIService(apiKey: appState.openAIKey)
                let result = try await service.summarize(
                    segments: attachment?.segments ?? [],
                    speakers: attachment?.speakers ?? [:],
                    notes: attachment?.notes ?? []
                )
                var updated = note
                updated.title = result.title
                updated.meetingAttachment?.summary = result.summary
                updated.meetingAttachment?.actionItems = result.actionItems
                note = updated
                appState.saveNote(updated)
            } catch {
                print("Summary regeneration failed: \(error)")
            }
            isRegenerating = false
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes < 1 { return "\(seconds)s" }
        return "\(minutes)m \(seconds)s"
    }

    private func exportNote() {
        let panel = NSSavePanel()
        panel.title = "Export Meeting Notes"
        panel.nameFieldStringValue = "\(note.title.isEmpty ? "Untitled Note" : note.title).md"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            let markdown = buildMarkdown()
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(note.title.isEmpty ? "Untitled Note" : note.title)")
        lines.append("")
        lines.append("**Date:** \(note.createdAt.formatted(date: .long, time: .shortened))")

        if attachment == nil {
            // Plain note export
            if !note.tags.isEmpty {
                lines.append("**Tags:** \(note.tags.joined(separator: ", "))")
            }
            lines.append("")
            if !note.body.isEmpty {
                lines.append(note.body)
            }
        } else {
            // Meeting note export
            if let dur = attachment?.duration {
                lines.append("**Duration:** \(formatDuration(dur))")
            }
            if !note.tags.isEmpty {
                lines.append("**Tags:** \(note.tags.joined(separator: ", "))")
            }
            lines.append("")

            if !note.body.isEmpty {
                lines.append(note.body)
                lines.append("")
            }

            if let summary = attachment?.summary, !summary.isEmpty {
                lines.append("## Summary")
                lines.append("")
                lines.append(summary)
                lines.append("")
            }

            if let items = attachment?.actionItems, !items.isEmpty {
                lines.append("## Action Items")
                lines.append("")
                for item in items {
                    lines.append("- \(item)")
                }
                lines.append("")
            }

            if let meetingNotes = attachment?.notes, !meetingNotes.isEmpty {
                lines.append("## Notes")
                lines.append("")
                for mn in meetingNotes {
                    lines.append("\(mn.formattedTimestamp) - \(mn.text)")
                }
                lines.append("")
            }

            if let segments = attachment?.segments, !segments.isEmpty {
                let speakers = attachment?.speakers ?? [:]
                lines.append("## Transcript")
                lines.append("")
                for segment in segments {
                    let name = speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)"
                    lines.append("**\(name):** \(segment.text)")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Speaker Rename Row

struct SpeakerRenameRow: View {
    let tag: Int
    @Binding var name: String
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text("Speaker \(tag)")
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Enter name…", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onCommit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { onCommit() }
                }
        }
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let speakers: [String: String]

    var speakerName: String {
        speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speakerName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(segment.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Meeting Chat View

struct MeetingChatView: View {
    @EnvironmentObject var appState: AppState
    @Binding var note: Note
    @State private var inputText = ""
    @State private var isSending = false
    @State private var isRunningAction = false

    private var chatMessages: [ChatMessage] {
        note.meetingAttachment?.chatMessages ?? []
    }

    private var isEmptyMeeting: Bool {
        (note.meetingAttachment?.segments ?? []).isEmpty &&
        note.meetingAttachment?.audioFilePath != nil
    }

    private var isBusy: Bool { isSending || isRunningAction }

    var body: some View {
        VStack(spacing: 0) {
            if chatMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    if isEmptyMeeting {
                        Text("Transcription failed for this meeting")
                            .fontWeight(.medium)
                        Text("You can recover it by retranscribing the audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retranscribe this meeting") {
                            sendText("Retranscribe this meeting")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                    } else {
                        Text("Ask anything about this meeting")
                            .foregroundStyle(.secondary)
                        Text("Or ask me to rename speakers, add tags, or regenerate the summary.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(chatMessages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                            if isSending {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").foregroundStyle(.secondary)
                                }
                                .padding(.leading, 4)
                            }
                            if isRunningAction {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Processing…").foregroundStyle(.secondary)
                                }
                                .padding(.leading, 4)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: chatMessages.count) { _, _ in
                        proxy.scrollTo(chatMessages.last?.id)
                    }
                    .onChange(of: isSending) { _, _ in
                        proxy.scrollTo(chatMessages.last?.id)
                    }
                    .onChange(of: isRunningAction) { _, _ in
                        proxy.scrollTo(chatMessages.last?.id)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        inputText = ""
        sendText(text)
    }

    private func sendText(_ text: String) {
        guard !isBusy else { return }

        let userMsg = ChatMessage(role: "user", content: text)
        var updated = note
        updated.meetingAttachment?.chatMessages.append(userMsg)
        note = updated
        appState.saveNote(updated)
        isSending = true

        Task {
            do {
                let service = OpenAIService(apiKey: appState.openAIKey)
                let attachment = note.meetingAttachment
                let transcript = attachment?.transcript(resolvingNames: true) ?? ""
                let speakers = attachment?.speakers ?? [:]
                let tags = note.tags
                let hasAudio = attachment?.audioFilePath != nil
                let hasTranscript = !(attachment?.segments ?? []).isEmpty
                let currentMessages = attachment?.chatMessages ?? []

                let response = try await service.chatWithMeetingControl(
                    messages: currentMessages,
                    transcript: transcript,
                    speakers: speakers,
                    tags: tags,
                    hasAudio: hasAudio,
                    hasTranscript: hasTranscript
                )

                isSending = false

                if response.mode == "action", let action = response.action {
                    var withConfirm = note
                    withConfirm.meetingAttachment?.chatMessages.append(
                        ChatMessage(role: "assistant", content: response.assistantMessage)
                    )
                    note = withConfirm
                    appState.saveNote(withConfirm)

                    isRunningAction = true
                    do {
                        let executor = MeetingActionExecutor(apiKey: appState.openAIKey)
                        let mutated = try await executor.execute(action, on: note)
                        note = mutated
                        appState.saveNote(mutated)
                    } catch {
                        var errNote = note
                        errNote.meetingAttachment?.chatMessages.append(
                            ChatMessage(role: "assistant", content: "Action failed: \(error.localizedDescription)")
                        )
                        note = errNote
                        appState.saveNote(errNote)
                    }
                    isRunningAction = false
                } else {
                    var finalNote = note
                    finalNote.meetingAttachment?.chatMessages.append(
                        ChatMessage(role: "assistant", content: response.assistantMessage)
                    )
                    note = finalNote
                    appState.saveNote(finalNote)
                }
            } catch {
                isSending = false
                var finalNote = note
                finalNote.meetingAttachment?.chatMessages.append(
                    ChatMessage(role: "assistant", content: "Sorry, something went wrong: \(error.localizedDescription)")
                )
                note = finalNote
                appState.saveNote(finalNote)
            }
        }
    }
}

// MARK: - Audio Player Bar

struct AudioPlayerBar: View {
    let url: URL
    @StateObject private var player = AudioPlayerController()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.onAccent)
            }
            .buttonStyle(.plain)

            Text(formatTime(player.currentTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.onMutedInk)
                .frame(width: 36)

            Slider(value: $player.currentTime, in: 0...max(player.duration, 1)) { editing in
                if !editing { player.seek(to: player.currentTime) }
            }

            Text(formatTime(player.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.onMutedInk)
                .frame(width: 36)
        }
        .onAppear { player.load(url: url) }
        .onDisappear { player.pause() }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

@MainActor
class AudioPlayerController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        player?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
            if !p.isPlaying { self.pause() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to time: Double) {
        player?.currentTime = time
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }
            Text(message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.role == "user" ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(message.role == "user" ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == "assistant" { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Editorial Tab Bar

struct EditorialTabBar: View {
    let tabs: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button(action: { withAnimation(.easeInOut(duration: 0.18)) { selection = i } }) {
                        VStack(spacing: 4) {
                            Text(tabs[i])
                                .font(selection == i ? .onHeadline : .onBody)
                                .foregroundStyle(selection == i ? Color.onInk : Color.onMutedInk)
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, Spacing.sm)

                            Rectangle()
                                .fill(selection == i ? Color.onAccent : Color.clear)
                                .frame(height: 2)
                                .padding(.horizontal, Spacing.sm)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.onPanel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.onSeparator)
                .frame(height: 1)
        }
    }
}
