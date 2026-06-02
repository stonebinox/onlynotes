import Foundation

struct MeetingActionExecutor {
    let apiKey: String
    let assemblyAIKey: String

    func execute(_ action: MeetingAction, on note: Note) async throws -> Note {
        var updated = note
        switch action.type {

        case "retranscribe":
            guard let audioPath = note.meetingAttachment?.audioFilePath,
                  FileManager.default.fileExists(atPath: audioPath) else {
                throw ActionError.noAudioFile
            }
            let systemURL = URL(fileURLWithPath: audioPath)

            let segments: [TranscriptSegment]
            if !assemblyAIKey.isEmpty {
                do {
                    // Hybrid: OpenAI transcription + AssemblyAI diarization (parallel)
                    let whisper = WhisperTranscriptionService(apiKey: apiKey)
                    let assemblyAI = AssemblyAITranscriptionService(apiKey: assemblyAIKey)

                    async let transcriptTask = whisper.transcribe(audioURL: systemURL)
                    async let diarizeTask = assemblyAI.diarize(url: systemURL)

                    let rawTranscript = try await transcriptTask
                    let diarization = try? await diarizeTask

                    if let diarization = diarization, !diarization.isEmpty {
                        segments = mergeSpeakerLabels(transcriptSegments: rawTranscript, diarization: diarization)
                    } else {
                        segments = rawTranscript.map { var s = $0; s.speakerTag = 2; return s }
                    }
                } catch {
                    print("Hybrid retranscribe failed, falling back to OpenAI-only: \(error.localizedDescription)")
                    let whisper = WhisperTranscriptionService(apiKey: apiKey)
                    segments = try await whisper.transcribe(systemURL: systemURL, micURL: nil)
                }
            } else {
                let whisper = WhisperTranscriptionService(apiKey: apiKey)
                segments = try await whisper.transcribe(systemURL: systemURL, micURL: nil)
            }

            updated.meetingAttachment?.segments = segments
            updated.meetingAttachment?.speakers = [:]
            let openAI = OpenAIService(apiKey: apiKey)
            let result = try await openAI.summarize(segments: segments, speakers: [:], notes: note.meetingAttachment?.notes ?? [])
            updated.title = result.title
            updated.meetingAttachment?.summary = result.summary
            updated.meetingAttachment?.actionItems = result.actionItems

        case "regenerate_summary":
            let segments = note.meetingAttachment?.segments ?? []
            let speakers = note.meetingAttachment?.speakers ?? [:]
            let openAI = OpenAIService(apiKey: apiKey)
            var notesForSummary = note.meetingAttachment?.notes ?? []
            if let ctx = action.context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notesForSummary.append(MeetingNote(timestampOffset: 0, text: "User context: \(ctx)"))
            }
            let result = try await openAI.summarize(segments: segments, speakers: speakers, notes: notesForSummary)
            updated.title = result.title
            updated.meetingAttachment?.summary = result.summary
            updated.meetingAttachment?.actionItems = result.actionItems

        case "rename_speaker":
            guard let tag = action.speakerTag,
                  let name = action.newName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionError.invalidArgs("rename_speaker requires speakerTag and newName")
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.meetingAttachment?.speakers[String(tag)] = trimmed

        case "add_tag":
            guard let tag = action.tag,
                  !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionError.invalidArgs("add_tag requires a non-empty tag")
            }
            updated.setTags(note.tags + [tag])

        case "remove_tag":
            guard let tag = action.tag else {
                throw ActionError.invalidArgs("remove_tag requires a tag")
            }
            updated.setTags(note.tags.filter { $0 != tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        case "translate":
            guard let targetLanguage = action.targetLanguage,
                  !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionError.invalidArgs("translate requires a targetLanguage")
            }
            let segments = note.meetingAttachment?.segments ?? []
            guard !segments.isEmpty else {
                throw ActionError.invalidArgs("No transcript to translate")
            }
            let openAI = OpenAIService(apiKey: apiKey)
            let translatedSegments = try await openAI.translateSegments(segments, to: targetLanguage)
            updated.meetingAttachment?.segments = translatedSegments
            // Regenerate summary with translated content
            let summaryResult = try await openAI.summarize(segments: translatedSegments, speakers: note.meetingAttachment?.speakers ?? [:], notes: note.meetingAttachment?.notes ?? [])
            updated.title = summaryResult.title
            updated.meetingAttachment?.summary = summaryResult.summary
            updated.meetingAttachment?.actionItems = summaryResult.actionItems

        default:
            throw ActionError.unknownAction(action.type)
        }

        updated.updatedAt = Date()
        return updated
    }
}

enum ActionError: LocalizedError {
    case noAudioFile
    case invalidArgs(String)
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case .noAudioFile: return "No audio file found for this meeting. Cannot retranscribe."
        case .invalidArgs(let msg): return "Invalid action arguments: \(msg)"
        case .unknownAction(let t): return "Unknown action type: \(t)"
        }
    }
}
