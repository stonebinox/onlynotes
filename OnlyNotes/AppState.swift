import AVFoundation
import CoreGraphics
import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isProcessing = false
    @Published var isImporting = false
    @Published var importError: String?
    @Published var processingError: String?
    @Published var liveNotes: [MeetingNote] = []
    @Published var liveNoteDraft: String = ""

    @AppStorage("openAIKey") var openAIKey: String = ""
    @AppStorage("braveSearchAPIKey") var braveSearchAPIKey: String = ""
    @AppStorage("assemblyAIKey") var assemblyAIKey: String = ""
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
    var preferredColorScheme: ColorScheme? { appearanceMode.colorScheme }

    let recorder = AudioRecorder()
    private var cancellables = Set<AnyCancellable>()

    var isRecording: Bool { recorder.isRecording }

    init() {
        NoteStore.shared.migrateIfNeeded()

        if let err = NoteStore.shared.migrationError {
            processingError = err
        }

        recorder.onUnexpectedStop = { [weak self] message in
            self?.processingError = message ?? "Recording stopped unexpectedly. Check audio permissions and try again."
        }
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func loadNotes() {
        notes = NoteStore.shared.loadAll()
        if let err = NoteStore.shared.loadError {
            processingError = err
        }
        let ids = Set(notes.map { $0.id })
        EmbeddingService.shared.pruneIndex(keeping: ids)
        let snapshot = notes
        let key = openAIKey
        Task.detached {
            for note in snapshot {
                await EmbeddingService.shared.indexNote(note, apiKey: key)
            }
        }
    }

    func saveNote(_ note: Note) {
        NoteStore.shared.save(note)
        loadNotes()
        Task.detached { [weak self] in
            guard let self else { return }
            await EmbeddingService.shared.indexNote(note, apiKey: self.openAIKey)
        }
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
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw RecorderError.screenCapturePermissionDenied
        }
        try recorder.startRecording()
    }

    func stopAndProcess(onNoteSaved: ((Note) -> Void)? = nil) {
        guard let result = recorder.stopRecording() else { return }
        isProcessing = true
        let capturedNotes = liveNotes

        Task {
            do {
                let openAIService = OpenAIService(apiKey: openAIKey)

                let segments: [TranscriptSegment]
                if !assemblyAIKey.isEmpty {
                    do {
                        // Hybrid: OpenAI for transcription + AssemblyAI for speaker diarization (parallel)
                        let whisper = WhisperTranscriptionService(apiKey: openAIKey)
                        let assemblyAI = AssemblyAITranscriptionService(apiKey: assemblyAIKey)

                        async let transcriptTask = whisper.transcribe(audioURL: result.systemURL)
                        async let diarizeTask = assemblyAI.diarize(url: result.systemURL)

                        let rawTranscript = try await transcriptTask
                        let diarization = try? await diarizeTask

                        var systemSegments: [TranscriptSegment]
                        if let diarization = diarization, !diarization.isEmpty {
                            systemSegments = mergeSpeakerLabels(transcriptSegments: rawTranscript, diarization: diarization)
                        } else {
                            print("AssemblyAI diarization empty/failed, using OpenAI transcript without speaker labels")
                            systemSegments = rawTranscript.map { var s = $0; s.speakerTag = 2; return s }
                        }

                        // Mic track (speaker 1)
                        var micSegments: [TranscriptSegment] = []
                        if let micURL = result.micURL,
                           FileManager.default.fileExists(atPath: micURL.path),
                           let attrs = try? FileManager.default.attributesOfItem(atPath: micURL.path),
                           (attrs[.size] as? Int ?? 0) > 4096 {
                            do {
                                let micResult = try await whisper.transcribe(audioURL: micURL)
                                micSegments = micResult.map { var s = $0; s.speakerTag = 1; return s }
                            } catch {
                                print("Mic transcription failed (non-fatal): \(error.localizedDescription)")
                            }
                        }

                        segments = (systemSegments + micSegments).sorted { $0.startTime < $1.startTime }
                    } catch {
                        print("Hybrid transcription failed, falling back to OpenAI-only: \(error.localizedDescription)")
                        let whisperService = WhisperTranscriptionService(apiKey: openAIKey)
                        segments = try await whisperService.transcribe(systemURL: result.systemURL, micURL: result.micURL)
                    }
                } else {
                    let whisperService = WhisperTranscriptionService(apiKey: openAIKey)
                    segments = try await whisperService.transcribe(systemURL: result.systemURL, micURL: result.micURL)
                }
                let summary = try await openAIService.summarize(segments: segments, speakers: [:], notes: capturedNotes)

                let attachment = MeetingAttachment(
                    segments: segments,
                    summary: summary.summary,
                    actionItems: summary.actionItems,
                    duration: result.duration,
                    audioFilePath: result.systemURL.path,
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
                    audioFilePath: result.systemURL.path,
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

    // MARK: - Audio Import

    func importAudio(into noteID: UUID, from sourceURL: URL) {
        guard !isImporting else { return }
        isImporting = true
        importError = nil

        Task {
            do {
                // 1. Copy file to app storage
                let appDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("OnlyNotes/ImportedAudio", isDirectory: true)
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                let destURL = appDir.appendingPathComponent("\(noteID.uuidString).\(sourceURL.pathExtension)")
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)

                // 2. Get duration
                let asset = AVURLAsset(url: destURL)
                let duration = CMTimeGetSeconds(asset.duration)

                // 3. Transcribe (hybrid if AssemblyAI key available)
                let segments: [TranscriptSegment]
                if !assemblyAIKey.isEmpty {
                    do {
                        let whisper = WhisperTranscriptionService(apiKey: openAIKey)
                        let assemblyAI = AssemblyAITranscriptionService(apiKey: assemblyAIKey)

                        async let transcriptTask = whisper.transcribe(audioURL: destURL)
                        async let diarizeTask = assemblyAI.diarize(url: destURL)

                        let rawTranscript = try await transcriptTask
                        let diarization = try? await diarizeTask

                        if let diarization = diarization, !diarization.isEmpty {
                            segments = mergeSpeakerLabels(transcriptSegments: rawTranscript, diarization: diarization)
                        } else {
                            segments = rawTranscript
                        }
                    } catch {
                        print("Hybrid import failed, falling back to OpenAI-only: \(error.localizedDescription)")
                        let whisperService = WhisperTranscriptionService(apiKey: openAIKey)
                        segments = try await whisperService.transcribe(audioURL: destURL)
                    }
                } else {
                    let whisperService = WhisperTranscriptionService(apiKey: openAIKey)
                    segments = try await whisperService.transcribe(audioURL: destURL)
                }

                // 4. Summarize
                let openAIService = OpenAIService(apiKey: openAIKey)
                let summary = try await openAIService.summarize(segments: segments, speakers: [:])

                // 5. Update note in place — preserve existing data
                await MainActor.run {
                    guard var existingNote = self.notes.first(where: { $0.id == noteID }) else {
                        self.importError = "Note no longer exists."
                        self.isImporting = false
                        return
                    }

                    let attachment = MeetingAttachment(
                        segments: segments,
                        summary: summary.summary,
                        actionItems: summary.actionItems,
                        duration: duration,
                        audioFilePath: destURL.path
                    )
                    existingNote.meetingAttachment = attachment
                    if existingNote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        existingNote.title = summary.title
                    }
                    existingNote.updatedAt = Date()

                    NoteStore.shared.save(existingNote)
                    self.loadNotes()
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.importError = error.localizedDescription
                    self.isImporting = false
                }
            }
        }
    }
}
