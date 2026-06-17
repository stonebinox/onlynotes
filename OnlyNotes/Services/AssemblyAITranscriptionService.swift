import Foundation

/// Transcribes audio using AssemblyAI with speaker diarization.
/// Speaker tags start at 2 to avoid collision with mic speaker tag 1.
class AssemblyAITranscriptionService {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Transcribes audio file at the given URL using AssemblyAI with speaker diarization.
    /// Speaker tags in returned segments start at 2.
    func transcribe(url: URL) async throws -> [TranscriptSegment] {
        let uploadURL = try await uploadFile(at: url)
        let transcriptID = try await submitTranscription(audioURL: uploadURL)
        let response = try await pollForCompletion(id: transcriptID)
        return try parseResponse(response)
    }

    /// Returns speaker diarization timing only (no transcript text).
    /// Speaker tags start at 2 to avoid collision with mic speaker 1.
    func diarize(url: URL) async throws -> [DiarizationSegment] {
        let uploadURL = try await uploadFile(at: url)
        let transcriptID = try await submitTranscription(audioURL: uploadURL)
        let response = try await pollForCompletion(id: transcriptID)
        return parseDiarization(response)
    }

    // MARK: - Upload

    private func uploadFile(at url: URL) async throws -> String {
        guard let apiURL = URL(string: "https://api.assemblyai.com/v2/upload") else {
            throw AssemblyAIError.uploadFailed("Invalid upload URL")
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AssemblyAIError.uploadFailed("HTTP \(code): \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadURL = json["upload_url"] as? String else {
            throw AssemblyAIError.uploadFailed("No upload_url in response")
        }

        return uploadURL
    }

    // MARK: - Submit

    private func submitTranscription(audioURL: String) async throws -> String {
        guard let apiURL = URL(string: "https://api.assemblyai.com/v2/transcript") else {
            throw AssemblyAIError.transcriptionFailed("Invalid transcript URL")
        }

        let body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": true,
            "language_detection": true
        ]

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AssemblyAIError.transcriptionFailed("Submit HTTP \(code): \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw AssemblyAIError.transcriptionFailed("No id in submit response")
        }

        return id
    }

    // MARK: - Poll

    private func pollForCompletion(id: String) async throws -> [String: Any] {
        guard let apiURL = URL(string: "https://api.assemblyai.com/v2/transcript/\(id)") else {
            throw AssemblyAIError.transcriptionFailed("Invalid poll URL")
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let maxPolls = 200
        for _ in 0..<maxPolls {
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown"
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw AssemblyAIError.transcriptionFailed("Poll HTTP \(code): \(msg)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                throw AssemblyAIError.transcriptionFailed("Invalid poll response")
            }

            switch status {
            case "completed":
                return json
            case "error":
                let msg = json["error"] as? String ?? "Unknown error"
                throw AssemblyAIError.transcriptionFailed(msg)
            default:
                continue
            }
        }

        throw AssemblyAIError.timeout
    }

    // MARK: - Parse

    private func parseResponse(_ json: [String: Any]) throws -> [TranscriptSegment] {
        var speakerMap: [String: Int] = [:]
        var nextTag = 2

        func tagFor(_ speaker: String) -> Int {
            if let existing = speakerMap[speaker] { return existing }
            let tag = nextTag
            speakerMap[speaker] = tag
            nextTag += 1
            return tag
        }

        if let utterances = json["utterances"] as? [[String: Any]], !utterances.isEmpty {
            return utterances.compactMap { utt -> TranscriptSegment? in
                guard let text = utt["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let startMs = utt["start"] as? Double,
                      let endMs = utt["end"] as? Double,
                      let speaker = utt["speaker"] as? String else { return nil }

                return TranscriptSegment(
                    speakerTag: tagFor(speaker),
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: startMs / 1000.0,
                    endTime: endMs / 1000.0
                )
            }
        }

        if let words = json["words"] as? [[String: Any]], !words.isEmpty {
            var segments: [TranscriptSegment] = []
            var groupText = ""
            var groupStart: Double = 0
            var groupEnd: Double = 0

            for (i, word) in words.enumerated() {
                guard let text = word["text"] as? String,
                      let startMs = word["start"] as? Double,
                      let endMs = word["end"] as? Double else { continue }

                if groupText.isEmpty {
                    groupStart = startMs
                }
                groupText += (groupText.isEmpty ? "" : " ") + text
                groupEnd = endMs

                if (i + 1) % 30 == 0 || i == words.count - 1 {
                    segments.append(TranscriptSegment(
                        speakerTag: 2,
                        text: groupText,
                        startTime: groupStart / 1000.0,
                        endTime: groupEnd / 1000.0
                    ))
                    groupText = ""
                }
            }
            return segments
        }

        if let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [TranscriptSegment(
                speakerTag: 2,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: 0,
                endTime: 0.01
            )]
        }

        throw AssemblyAIError.parseError("No utterances, words, or text in response")
    }

    // MARK: - Diarization-Only Parsing

    private func parseDiarization(_ json: [String: Any]) -> [DiarizationSegment] {
        var speakerMap: [String: Int] = [:]
        var nextTag = 2

        func tagFor(_ speaker: String) -> Int {
            if let existing = speakerMap[speaker] { return existing }
            let tag = nextTag
            speakerMap[speaker] = tag
            nextTag += 1
            return tag
        }

        if let utterances = json["utterances"] as? [[String: Any]], !utterances.isEmpty {
            return utterances.compactMap { utt -> DiarizationSegment? in
                guard let startMs = utt["start"] as? Double,
                      let endMs = utt["end"] as? Double,
                      let speaker = utt["speaker"] as? String else { return nil }
                let text = (utt["text"] as? String) ?? ""
                return DiarizationSegment(
                    speakerTag: tagFor(speaker),
                    startTime: startMs / 1000.0,
                    endTime: endMs / 1000.0,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        return []
    }
}

// MARK: - Diarization Segment

struct DiarizationSegment {
    let speakerTag: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

// MARK: - Hybrid Merge

/// Merges OpenAI chunk-level transcript text with AssemblyAI per-utterance diarization.
/// Each TranscriptSegment in `transcriptSegments` is one OpenAI chunk (text blob with
/// startTime = chunk offset). For each chunk, AssemblyAI utterances whose midpoint falls
/// inside the chunk get a slice of the OpenAI text proportional to their AssemblyAI text
/// length, cut at word boundaries. Returns one TranscriptSegment per utterance.
func mergeSpeakerLabels(transcriptSegments: [TranscriptSegment], diarization: [DiarizationSegment]) -> [TranscriptSegment] {
    guard !diarization.isEmpty else { return transcriptSegments }

    // Separate real transcript chunks (speakerTag != 0) from synthetic warning markers (speakerTag == 0).
    // Warning markers must not be treated as chunks to slice — they get appended verbatim at the end.
    let warningSegments = transcriptSegments.filter { $0.speakerTag == 0 }
    let realChunks = transcriptSegments.filter { $0.speakerTag != 0 }

    guard !realChunks.isEmpty else {
        let utteranceSegments = diarization.map { d in
            TranscriptSegment(
                speakerTag: d.speakerTag,
                text: d.text,
                startTime: d.startTime,
                endTime: d.endTime
            )
        }
        return utteranceSegments + warningSegments
    }

    let sortedChunks = realChunks.sorted { $0.startTime < $1.startTime }

    // WhisperTranscriptionService chunks are chunkDuration (720s) + overlapDuration (20s) = 740s of audio,
    // so each chunk's OpenAI text covers MORE time than the gap to the next chunk's startTime. We trim a
    // trailing fraction of each non-last chunk's text to drop the overlap window — otherwise text "drifts"
    // at chunk boundaries and earlier utterances get slices of words spoken inside the overlap (which
    // properly belong to early utterances of the next chunk).
    let chunkDuration: TimeInterval = 720
    let overlapDuration: TimeInterval = 20
    let maxChunkExtent: TimeInterval = chunkDuration + overlapDuration + 60  // safety margin past partial-failure boundary

    // Trim each chunk's text to drop overlap content on BOTH sides:
    //   - Non-first chunks share their first ~overlap seconds with the previous chunk's tail.
    //   - Non-last chunks share their last ~overlap seconds with the next chunk's head.
    // We approximate by trimming overlap/(chunkDuration + overlap) fraction of characters at each
    // affected boundary. This is a uniform-density heuristic — drift is bounded by the overlap
    // ratio (~2.7%); precise alignment would need per-word timestamps that gpt-4o-mini-transcribe
    // does not return. Tracked as a follow-up.
    let overlapRatio = overlapDuration / (chunkDuration + overlapDuration)

    var chunkRanges: [(start: TimeInterval, end: TimeInterval, text: String)] = []
    for (i, chunk) in sortedChunks.enumerated() {
        let isFirst = (i == 0)
        let isLast = (i + 1 == sortedChunks.count)
        let end = isLast ? chunk.startTime + maxChunkExtent : sortedChunks[i + 1].startTime

        let chars = Array(chunk.text)
        let total = chars.count
        let headTrim = isFirst ? 0 : Int((Double(total) * overlapRatio).rounded())
        let tailKeep = isLast ? total : Int((Double(total) * (1.0 - overlapRatio)).rounded())

        let headBoundary = headTrim > 0 ? nearestWordBoundary(chars: chars, target: headTrim, maxSearch: 30) : 0
        let tailBoundary = tailKeep < total ? nearestWordBoundary(chars: chars, target: tailKeep, maxSearch: 30) : total

        let text: String
        if headBoundary < tailBoundary && tailBoundary <= total {
            text = String(chars[headBoundary..<tailBoundary])
        } else {
            text = chunk.text
        }
        chunkRanges.append((chunk.startTime, end, text))
    }

    // Group AssemblyAI utterances by which chunk they belong to (by midpoint).
    var utterancesByChunk: [Int: [DiarizationSegment]] = [:]
    var unassigned: [DiarizationSegment] = []
    for u in diarization {
        let midpoint = (u.startTime + u.endTime) / 2
        if let chunkIdx = chunkRanges.firstIndex(where: { midpoint >= $0.start && midpoint < $0.end }) {
            utterancesByChunk[chunkIdx, default: []].append(u)
        } else {
            unassigned.append(u)
        }
    }

    var result: [TranscriptSegment] = []

    for chunkIdx in utterancesByChunk.keys.sorted() {
        guard let chunkUtterances = utterancesByChunk[chunkIdx] else { continue }
        let chunkText = chunkRanges[chunkIdx].text
        let sortedUtterances = chunkUtterances.sorted { $0.startTime < $1.startTime }

        let totalAssemblyChars = sortedUtterances.reduce(0) { $0 + $1.text.count }
        let chunkChars = Array(chunkText)
        let chunkCharCount = chunkChars.count

        // Fallback: if there's no OpenAI text or no AssemblyAI text to base proportions on,
        // emit utterances using AssemblyAI's own text.
        guard totalAssemblyChars > 0, chunkCharCount > 0 else {
            for u in sortedUtterances {
                result.append(TranscriptSegment(
                    speakerTag: u.speakerTag,
                    text: u.text,
                    startTime: u.startTime,
                    endTime: u.endTime
                ))
            }
            continue
        }

        var charPos = 0
        for (i, u) in sortedUtterances.enumerated() {
            let proportion = Double(u.text.count) / Double(totalAssemblyChars)
            let rawEnd: Int
            if i == sortedUtterances.count - 1 {
                rawEnd = chunkCharCount
            } else {
                let target = charPos + Int((Double(chunkCharCount) * proportion).rounded())
                rawEnd = min(max(target, charPos), chunkCharCount)
            }
            // nearestWordBoundary can snap backward; clamp to keep cursor monotonic so we never reuse
            // already-consumed characters in subsequent utterances.
            let snapped = nearestWordBoundary(chars: chunkChars, target: rawEnd, maxSearch: 15)
            let adjustedEnd = max(snapped, charPos)

            let slicedText: String
            if charPos < adjustedEnd && adjustedEnd <= chunkCharCount {
                slicedText = String(chunkChars[charPos..<adjustedEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                slicedText = ""
            }

            result.append(TranscriptSegment(
                speakerTag: u.speakerTag,
                text: slicedText.isEmpty ? u.text : slicedText,
                startTime: u.startTime,
                endTime: u.endTime
            ))

            charPos = adjustedEnd
        }
    }

    // Utterances outside all chunk ranges (rare) — emit with AssemblyAI text.
    for u in unassigned {
        result.append(TranscriptSegment(
            speakerTag: u.speakerTag,
            text: u.text,
            startTime: u.startTime,
            endTime: u.endTime
        ))
    }

    // Chunks that had no matching AssemblyAI utterances — never drop their OpenAI text.
    // Emit as a single segment with the original chunk's speakerTag (Whisper placeholder, typically 1)
    // so the caller's retag logic can adjust if needed (e.g. system audio retags 1 → 2).
    let chunkIdxsWithUtterances = Set(utterancesByChunk.keys)
    for i in 0..<chunkRanges.count where !chunkIdxsWithUtterances.contains(i) {
        let range = chunkRanges[i]
        let trimmed = range.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        result.append(TranscriptSegment(
            speakerTag: sortedChunks[i].speakerTag,
            text: trimmed,
            startTime: range.start,
            endTime: range.start + 0.01
        ))
    }

    return result.sorted { $0.startTime < $1.startTime } + warningSegments
}

private func nearestWordBoundary(chars: [Character], target: Int, maxSearch: Int) -> Int {
    guard target > 0, target < chars.count else { return target }
    for offset in 0..<maxSearch {
        let back = target - offset
        if back >= 0, chars[back].isWhitespace { return back }
        let fwd = target + offset
        if fwd < chars.count, chars[fwd].isWhitespace { return fwd }
    }
    return target
}

enum AssemblyAIError: LocalizedError {
    case uploadFailed(String)
    case transcriptionFailed(String)
    case timeout
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "AssemblyAI upload failed: \(msg)"
        case .transcriptionFailed(let msg): return "AssemblyAI transcription failed: \(msg)"
        case .timeout: return "AssemblyAI transcription timed out after 10 minutes."
        case .parseError(let msg): return "AssemblyAI parse error: \(msg)"
        }
    }
}
