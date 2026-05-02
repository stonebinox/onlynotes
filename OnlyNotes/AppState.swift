import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var isProcessing = false
    @Published var processingError: String?
    @Published var liveNotes: [MeetingNote] = []
    @Published var liveNoteDraft: String = ""

    @AppStorage("openAIKey") var openAIKey: String = ""
    @AppStorage("googleAPIKey") var googleAPIKey: String = ""
    @AppStorage("googleBucketName") var googleBucketName: String = ""

    let recorder = AudioRecorder()
    private var cancellables = Set<AnyCancellable>()

    var isRecording: Bool { recorder.isRecording }

    init() {
        recorder.onUnexpectedStop = { [weak self] in
            self?.processingError = "Recording stopped unexpectedly. Check your microphone."
        }
        // Forward recorder @Published changes so views observing AppState update too
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func loadMeetings() {
        meetings = MeetingStore.shared.loadAll()
    }

    func deleteMeeting(_ meeting: Meeting) {
        MeetingStore.shared.delete(meeting)
        loadMeetings()
    }

    func saveMeeting(_ meeting: Meeting) {
        MeetingStore.shared.save(meeting)
        loadMeetings()
    }

    func startRecording() throws {
        processingError = nil
        try recorder.startRecording()
    }

    func addLiveNote() {
        let text = liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = MeetingNote(timestampOffset: recorder.elapsedTime, text: text)
        liveNotes.append(note)
        liveNoteDraft = ""
    }

    func stopAndProcess(onMeetingSaved: ((Meeting) -> Void)? = nil) {
        guard let result = recorder.stopRecording() else { return }
        isProcessing = true
        let capturedNotes = liveNotes

        let bucket = googleBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            processingError = "GCS bucket name is required. Add it in Settings."
            isProcessing = false
            return
        }

        Task {
            do {
                let speechService = GoogleSpeechService(apiKey: googleAPIKey)
                let openAIService = OpenAIService(apiKey: openAIKey)

                let segments = try await speechService.transcribe(audioURL: result.url, bucket: bucket)
                let summary = try await openAIService.summarize(segments: segments, speakers: [:], notes: capturedNotes)

                var meeting = Meeting(
                    title: summary.title,
                    date: Date(),
                    duration: result.duration,
                    segments: segments,
                    summary: summary.summary,
                    actionItems: summary.actionItems,
                    audioFilePath: result.url.path
                )
                meeting.notes = capturedNotes
                MeetingStore.shared.save(meeting)

                await MainActor.run {
                    self.loadMeetings()
                    self.isProcessing = false
                    self.liveNotes = []
                    self.liveNoteDraft = ""
                    onMeetingSaved?(meeting)
                }
            } catch {
                var meeting = Meeting(
                    title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                    date: Date(),
                    duration: result.duration,
                    audioFilePath: result.url.path
                )
                meeting.notes = capturedNotes
                MeetingStore.shared.save(meeting)

                await MainActor.run {
                    self.loadMeetings()
                    self.processingError = error.localizedDescription
                    self.isProcessing = false
                    self.liveNotes = []
                    self.liveNoteDraft = ""
                }
            }
        }
    }
}
