import Foundation
import AVFoundation

/// Transcribes audio using OpenAI Whisper (chunked) + GPT-4o speaker inference.
class WhisperTranscriptionService {
    private let apiKey: String
    private let chunkDuration: TimeInterval = 720  // 12 minutes
    private let overlapDuration: TimeInterval = 20  // 20 seconds overlap

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Public

    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        let chunks = try splitAudio(url: audioURL)
        var allSegments: [TranscriptSegment] = []
        var partialWarning: String? = nil

        for (index, chunk) in chunks.enumerated() {
            do {
                let raw = try await transcribeChunk(url: chunk.url, offset: chunk.startTime)
                allSegments.append(contentsOf: raw)
            } catch {
                partialWarning = "Chunk \(index + 1)/\(chunks.count) failed: \(error.localizedDescription). Saving partial transcript."
                print("WhisperTranscriptionService: \(partialWarning!)")
                break  // save what we have
            }
        }

        // Clean up temp chunk files
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.url)
        }

        let merged = dedupeOverlap(allSegments)
        let withSpeakers = await inferSpeakers(segments: merged)

        if let warning = partialWarning {
            // Prepend a marker segment so the warning surfaces in the transcript
            let marker = TranscriptSegment(
                speakerTag: 0,
                text: "⚠️ \(warning)",
                startTime: (withSpeakers.last?.endTime ?? 0) + 1,
                endTime: (withSpeakers.last?.endTime ?? 0) + 1
            )
            return withSpeakers + [marker]
        }

        return withSpeakers
    }

    // MARK: - Audio Splitting

    private struct AudioChunk {
        let url: URL
        let startTime: TimeInterval
    }

    private func splitAudio(url: URL) throws -> [AudioChunk] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)

        guard duration > 0 else { throw WhisperError.invalidAudio }

        // Single chunk — no splitting needed
        if duration <= chunkDuration + overlapDuration {
            return [AudioChunk(url: url, startTime: 0)]
        }

        var chunks: [AudioChunk] = []
        var chunkStart: TimeInterval = 0
        let tempDir = FileManager.default.temporaryDirectory

        while chunkStart < duration {
            let chunkEnd = min(chunkStart + chunkDuration + overlapDuration, duration)
            let startCM = CMTime(seconds: chunkStart, preferredTimescale: 44100)
            let endCM = CMTime(seconds: chunkEnd, preferredTimescale: 44100)
            let timeRange = CMTimeRange(start: startCM, end: endCM)

            let chunkURL = tempDir.appendingPathComponent("chunk_\(Int(chunkStart)).wav")

            try exportChunk(asset: asset, timeRange: timeRange, to: chunkURL)
            chunks.append(AudioChunk(url: chunkURL, startTime: chunkStart))

            chunkStart += chunkDuration
        }

        return chunks
    }

    private func exportChunk(asset: AVURLAsset, timeRange: CMTimeRange, to outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw WhisperError.exportFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .wav
        exportSession.timeRange = timeRange

        let sema = DispatchSemaphore(value: 0)
        var exportError: Error? = nil

        exportSession.exportAsynchronously {
            if exportSession.status == .failed {
                exportError = exportSession.error
            }
            sema.signal()
        }
        sema.wait()

        if let err = exportError { throw err }
        guard exportSession.status == .completed else {
            throw WhisperError.exportFailed
        }
    }

    // MARK: - Whisper Transcription

    private func transcribeChunk(url: URL, offset: TimeInterval) async throws -> [TranscriptSegment] {
        let audioData = try Data(contentsOf: url)
        guard !audioData.isEmpty else { return [] }

        guard let apiURL = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw WhisperError.invalidConfig
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300  // 5 min for large chunks

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        // model field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("whisper-1\r\n")

        // response_format field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("verbose_json\r\n")

        // timestamp_granularities field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n")
        append("segment\r\n")

        // audio file
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.transcriptionFailed("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw WhisperError.transcriptionFailed("HTTP \(http.statusCode): \(msg)")
        }

        return parseWhisperResponse(data: data, offset: offset)
    }

    private func parseWhisperResponse(data: Data, offset: TimeInterval) -> [TranscriptSegment] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else { return [] }

        return segments.compactMap { seg -> TranscriptSegment? in
            guard let text = seg["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let start = (seg["start"] as? Double ?? 0) + offset
            let end = max((seg["end"] as? Double ?? 0) + offset, start + 0.01)

            return TranscriptSegment(
                speakerTag: 1,  // placeholder until inference pass
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: start,
                endTime: end
            )
        }
    }

    // MARK: - Overlap Deduplication

    private func dedupeOverlap(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.count > 1 else { return segments }

        var result: [TranscriptSegment] = []
        var seenTexts: Set<String> = []

        for segment in segments {
            let normalized = segment.text
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if seenTexts.contains(normalized) { continue }

            // Check for near-duplicate (substring match for short segments)
            var isDuplicate = false
            if normalized.count < 80 {
                for seen in seenTexts {
                    if seen.contains(normalized) || normalized.contains(seen) {
                        isDuplicate = true
                        break
                    }
                }
            }

            if !isDuplicate {
                seenTexts.insert(normalized)
                result.append(segment)
            }
        }

        // Ensure monotonically non-decreasing timestamps
        var lastEnd: TimeInterval = 0
        return result.map { seg in
            var s = seg
            if s.startTime < lastEnd { s.startTime = lastEnd }
            if s.endTime < s.startTime { s.endTime = s.startTime + 0.01 }
            lastEnd = s.endTime
            return s
        }
    }

    // MARK: - GPT-4o Speaker Inference

    private func inferSpeakers(segments: [TranscriptSegment]) async -> [TranscriptSegment] {
        guard !segments.isEmpty, !apiKey.isEmpty else { return segments }

        // Build compact representation for GPT-4o
        let segList = segments.enumerated().map { (i, seg) in
            ["index": i, "start": Int(seg.startTime), "text": seg.text] as [String: Any]
        }

        let systemPrompt = """
        You are a speaker diarization assistant. Assign speaker IDs to transcript segments.
        Rules:
        - Assign stable integer speaker_id values starting from 1
        - Keep speaker IDs consistent across the entire transcript
        - Base assignments on conversational patterns (questions/answers, topic shifts, addressing others)
        - Do not invent more speakers than clearly present
        - Do not split segments unless you are highly confident they contain two different speakers
        Respond with ONLY a JSON object in this exact format:
        {"speaker_count": N, "assignments": [{"segment_index": 0, "speaker_id": 1}, ...]}
        """

        let userContent: [String: Any] = [
            "segments": segList
        ]

        guard let userJSON = try? JSONSerialization.data(withJSONObject: userContent),
              let userText = String(data: userJSON, encoding: .utf8) else {
            return segments
        }

        let payload: [String: Any] = [
            "model": "gpt-4o",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "max_tokens": 4096
        ]

        guard let apiURL = URL(string: "https://api.openai.com/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return segments
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 60

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let resultData = content.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let assignments = result["assignments"] as? [[String: Any]]
        else {
            // Fallback: all speaker 1
            return segments
        }

        var tagMap: [Int: Int] = [:]
        for assignment in assignments {
            if let idx = assignment["segment_index"] as? Int,
               let spk = assignment["speaker_id"] as? Int {
                tagMap[idx] = spk
            }
        }

        return segments.enumerated().map { (i, seg) in
            var s = seg
            s.speakerTag = tagMap[i] ?? 1
            return s
        }
    }
}

enum WhisperError: LocalizedError {
    case invalidAudio
    case invalidConfig
    case exportFailed
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "Audio file is empty or unreadable."
        case .invalidConfig: return "Invalid Whisper API configuration."
        case .exportFailed: return "Failed to export audio chunk."
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        }
    }
}
