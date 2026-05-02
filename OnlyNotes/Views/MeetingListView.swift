import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = AudioRecorder()
    @Binding var selectedMeeting: Meeting?
    @State private var isProcessing = false
    @State private var processingError: String?

    var body: some View {
        List(selection: $selectedMeeting) {
            Section {
                recordButton
            }

            if let error = processingError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
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
        .onAppear {
            recorder.onUnexpectedStop = {
                appState.isRecording = false
                processingError = "Recording stopped unexpectedly. Check your microphone."
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if isProcessing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                processingError = nil
                if recorder.isRecording {
                    stopAndProcess()
                } else {
                    startRecording()
                }
            } label: {
                HStack {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(recorder.isRecording ? "Stop Recording" : "Start Recording")
                            .fontWeight(.medium)
                        if recorder.isRecording {
                            Text(formatTime(recorder.elapsedTime))
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

    private func startRecording() {
        do {
            try recorder.startRecording()
            appState.isRecording = true
        } catch {
            processingError = error.localizedDescription
        }
    }

    private func stopAndProcess() {
        guard let result = recorder.stopRecording() else { return }
        appState.isRecording = false
        isProcessing = true

        Task {
            do {
                let speechService = GoogleSpeechService(apiKey: appState.googleAPIKey)
                let openAIService = OpenAIService(apiKey: appState.openAIKey)

                let segments = try await speechService.transcribe(audioURL: result.url)
                let summary = try await openAIService.summarize(segments: segments, speakers: [:])

                let meeting = Meeting(
                    title: summary.title,
                    date: Date(),
                    duration: result.duration,
                    segments: segments,
                    summary: summary.summary,
                    actionItems: summary.actionItems,
                    audioFilePath: result.url.path
                )

                MeetingStore.shared.save(meeting)

                await MainActor.run {
                    appState.loadMeetings()
                    selectedMeeting = meeting
                    isProcessing = false
                }
            } catch {
                // Save with raw segments even if summarization fails
                let meeting = Meeting(
                    title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                    date: Date(),
                    duration: result.duration,
                    audioFilePath: result.url.path
                )
                MeetingStore.shared.save(meeting)

                await MainActor.run {
                    appState.loadMeetings()
                    processingError = error.localizedDescription
                    isProcessing = false
                }
            }
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
