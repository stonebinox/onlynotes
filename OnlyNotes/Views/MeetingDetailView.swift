import SwiftUI
import AVFoundation

struct MeetingDetailView: View {
    @EnvironmentObject var appState: AppState
    @State var meeting: Meeting
    @State private var selectedTab = 0
    @State private var isRegenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title)
                    .font(.title)
                    .fontWeight(.bold)

                HStack(spacing: 16) {
                    Label(meeting.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label(formatDuration(meeting.duration), systemImage: "clock")
                    if !meeting.segments.isEmpty {
                        Label("\(speakerCount) speakers", systemImage: "person.2")
                    }
                    Spacer()
                    Button(action: exportMeeting) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let path = meeting.audioFilePath {
                    AudioPlayerBar(url: URL(fileURLWithPath: path))
                }
            }
            .padding()

            Divider()

            Picker("", selection: $selectedTab) {
                Text("Summary").tag(0)
                Text("Action Items").tag(1)
                Text("Speakers").tag(2)
                Text("Transcript").tag(3)
                Text("Chat").tag(4)
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case 0: summaryView
                    case 1: actionItemsView
                    case 2: speakersView
                    case 3: transcriptView
                    case 4: chatView
                    default: EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var summaryView: some View {
        if isRegenerating {
            HStack { ProgressView().controlSize(.small); Text("Regenerating summary…").foregroundStyle(.secondary) }
        } else if meeting.summary.isEmpty {
            Text("No summary available").foregroundStyle(.secondary).italic()
        } else {
            Text(meeting.summary).lineSpacing(4)
        }
    }

    @ViewBuilder
    private var actionItemsView: some View {
        if meeting.actionItems.isEmpty {
            Text("No action items").foregroundStyle(.secondary).italic()
        } else {
            ForEach(meeting.actionItems, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    Text(item)
                }
            }
        }
    }

    @ViewBuilder
    private var speakersView: some View {
        if meeting.segments.isEmpty {
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
                            get: { meeting.speakers[String(tag)] ?? "" },
                            set: { newName in
                                var updated = meeting
                                if newName.isEmpty {
                                    updated.speakers.removeValue(forKey: String(tag))
                                } else {
                                    updated.speakers[String(tag)] = newName
                                }
                                meeting = updated
                                appState.saveMeeting(updated)
                            }
                        )
                    )
                }

                if !meeting.speakers.isEmpty {
                    Button("Regenerate Summary with Speaker Names") {
                        regenerateSummary()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRegenerating)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if meeting.segments.isEmpty {
            Text("No transcript available").foregroundStyle(.secondary).italic()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(meeting.segments) { segment in
                    TranscriptSegmentRow(segment: segment, speakers: meeting.speakers)
                }
            }
        }
    }

    @ViewBuilder
    private var chatView: some View {
        MeetingChatView(meeting: $meeting)
    }

    // MARK: - Helpers

    private var uniqueSpeakerTags: [Int] {
        Array(Set(meeting.segments.map(\.speakerTag))).sorted()
    }

    private var speakerCount: Int {
        uniqueSpeakerTags.count
    }

    private func regenerateSummary() {
        isRegenerating = true
        Task {
            do {
                let service = OpenAIService(apiKey: appState.openAIKey)
                let result = try await service.summarize(segments: meeting.segments, speakers: meeting.speakers)
                var updated = meeting
                updated.title = result.title
                updated.summary = result.summary
                updated.actionItems = result.actionItems
                meeting = updated
                appState.saveMeeting(updated)
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

    private func exportMeeting() {
        let panel = NSSavePanel()
        panel.title = "Export Meeting Notes"
        panel.nameFieldStringValue = "\(meeting.title).md"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            let markdown = buildMarkdown()
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("**Date:** \(meeting.date.formatted(date: .long, time: .shortened))")
        lines.append("**Duration:** \(formatDuration(meeting.duration))")
        lines.append("")

        if !meeting.summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(meeting.summary)
            lines.append("")
        }

        if !meeting.actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for item in meeting.actionItems {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        if !meeting.segments.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            for segment in meeting.segments {
                let name = meeting.speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)"
                lines.append("**\(name):** \(segment.text)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Speaker Rename Row

struct SpeakerRenameRow: View {
    let tag: Int
    @Binding var name: String
    @State private var editingName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text("Speaker \(tag)")
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Enter name…", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onAppear { editingName = name }
                .onChange(of: isFocused) { _, focused in
                    if !focused { name = editingName }
                }
                .onSubmit { name = editingName }
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
    @Binding var meeting: Meeting
    @State private var inputText = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            if meeting.chatMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Ask anything about this meeting")
                        .foregroundStyle(.secondary)
                    Text("e.g. \"What did we decide about the timeline?\"")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(meeting.chatMessages) { msg in
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
                        }
                        .padding()
                    }
                    .onChange(of: meeting.chatMessages.count) { _, _ in
                        proxy.scrollTo(meeting.chatMessages.last?.id)
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
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        var updated = meeting
        updated.chatMessages.append(userMsg)
        meeting = updated
        appState.saveMeeting(updated)
        inputText = ""
        isSending = true

        Task {
            do {
                let service = OpenAIService(apiKey: appState.openAIKey)
                let transcript = meeting.transcript(resolvingNames: true)
                let reply = try await service.chat(messages: updated.chatMessages, transcript: transcript)

                var final = meeting
                final.chatMessages.append(ChatMessage(role: .assistant, content: reply))
                meeting = final
                appState.saveMeeting(final)
            } catch {
                var final = meeting
                final.chatMessages.append(ChatMessage(role: .assistant, content: "Sorry, something went wrong: \(error.localizedDescription)"))
                meeting = final
                appState.saveMeeting(final)
            }
            isSending = false
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
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Text(formatTime(player.currentTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36)

            Slider(value: $player.currentTime, in: 0...max(player.duration, 1)) { editing in
                if !editing { player.seek(to: player.currentTime) }
            }

            Text(formatTime(player.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
            if message.role == .user { Spacer(minLength: 60) }
            Text(message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
