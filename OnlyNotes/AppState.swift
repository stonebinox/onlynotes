import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isProcessing = false
    @Published var processingError: String?
    @Published var liveNotes: [MeetingNote] = []
    @Published var liveNoteDraft: String = ""

    @AppStorage("openAIKey") var openAIKey: String = ""
    @AppStorage("googleAPIKey") var googleAPIKey: String = ""
    @AppStorage("googleBucketName") var googleBucketName: String = ""
    @AppStorage("braveSearchAPIKey") var braveSearchAPIKey: String = ""

    let recorder = AudioRecorder()
    private var cancellables = Set<AnyCancellable>()

    var isRecording: Bool { recorder.isRecording }

    init() {
        NoteStore.shared.migrateIfNeeded()

        if let err = NoteStore.shared.migrationError {
            processingError = err
        }

        recorder.onUnexpectedStop = { [weak self] in
            self?.processingError = "Recording stopped unexpectedly. Check your microphone."
        }
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func loadNotes() {
        notes = NoteStore.shared.loadAll()
    }

    func saveNote(_ note: Note) {
        NoteStore.shared.save(note)
        loadNotes()
    }

    func deleteNote(_ note: Note) {
        NoteStore.shared.delete(note)
        loadNotes()
    }

    func addLiveNote() {
        let text = liveNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = MeetingNote(timestampOffset: recorder.elapsedTime, text: text)
        liveNotes.append(note)
        liveNoteDraft = ""
    }

    func startRecording() throws {
        processingError = nil
        try recorder.startRecording()
    }

    func stopAndProcess(onNoteSaved: ((Note) -> Void)? = nil) {
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

                let attachment = MeetingAttachment(
                    segments: segments,
                    summary: summary.summary,
                    actionItems: summary.actionItems,
                    duration: result.duration,
                    audioFilePath: result.url.path,
                    notes: capturedNotes
                )
                let note = Note(
                    title: summary.title,
                    createdAt: Date(),
                    updatedAt: Date(),
                    meetingAttachment: attachment
                )

                NoteStore.shared.save(note)

                await MainActor.run {
                    self.loadNotes()
                    self.isProcessing = false
                    self.liveNotes = []
                    self.liveNoteDraft = ""
                    onNoteSaved?(note)
                }
            } catch {
                let attachment = MeetingAttachment(
                    duration: result.duration,
                    audioFilePath: result.url.path,
                    notes: capturedNotes
                )
                let note = Note(
                    title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                    createdAt: Date(),
                    updatedAt: Date(),
                    meetingAttachment: attachment
                )
                NoteStore.shared.save(note)

                await MainActor.run {
                    self.loadNotes()
                    self.processingError = error.localizedDescription
                    self.isProcessing = false
                    self.liveNotes = []
                    self.liveNoteDraft = ""
                }
            }
        }
    }
}
