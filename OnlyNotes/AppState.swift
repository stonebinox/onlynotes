import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var isProcessing = false
    @Published var processingError: String?

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

    func stopAndProcess(onMeetingSaved: ((Meeting) -> Void)? = nil) {
        guard let result = recorder.stopRecording() else { return }
        isProcessing = true

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
                    self.loadMeetings()
                    self.isProcessing = false
                    onMeetingSaved?(meeting)
                }
            } catch {
                let meeting = Meeting(
                    title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                    date: Date(),
                    duration: result.duration,
                    audioFilePath: result.url.path
                )
                MeetingStore.shared.save(meeting)

                await MainActor.run {
                    self.loadMeetings()
                    self.processingError = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
}
