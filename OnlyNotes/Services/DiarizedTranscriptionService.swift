import Foundation
import AVFoundation

/// Transcribes audio using OpenAI gpt-4o-transcribe-diarize, obtaining transcript text and
/// speaker labels from a single API call (or multiple silence-split chunks for long recordings).
class DiarizedTranscriptionService {
    private let apiKey: String

    // MARK: - Constants

    /// Files shorter than this AND smaller than singleCallMaxFileSize go in one request.
    private static let singleCallMaxDuration: TimeInterval = 540   // 9 min
    /// Files smaller than this AND shorter than singleCallMaxDuration go in one request.
    private static let singleCallMaxFileSize: Int = 24 * 1024 * 1024  // 24 MB
    /// Target chunk length when splitting is necessary (~5.75 min keeps well under limits).
    private static let chunkTargetDuration: TimeInterval = 345
    /// Search ±this many seconds around the target cut point for a silence trough.
    private static let silenceSearchWindow: TimeInterval = 60
    /// Never cut sooner than this many seconds into a chunk (avoids tiny leading chunks).
    private static let minChunkDuration: TimeInterval = 60
    /// RMS energy window size for silence detection.
    private static let rmsWindowSeconds: TimeInterval = 0.030
    /// A window is considered silent if its RMS energy is at or below silenceFactor × medianEnergy.
    private static let silenceFactor: Float = 0.20
    /// Minimum consecutive silent windows required to qualify as a cut point (~200 ms at 30 ms/window).
    private static let minSilenceRunSeconds: TimeInterval = 0.200
    /// Each chunk gets a disjoint speaker tag namespace; tags span at most this many values.
    private static let speakerNamespaceStride: Int = 50

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Public

    /// Transcribe `audioURL` and return segments with speaker tags starting at `speakerTagOffset`.
    /// Short/small recordings make exactly one API request. Longer ones are silence-split into
    /// chunks with disjoint per-chunk speaker tag namespaces; the caller is responsible for
    /// running consolidateSpeakerTags afterwards to reconcile them.
    func transcribe(audioURL: URL, speakerTagOffset: Int) async throws -> [TranscriptSegment] {
        let asset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { throw DiarizedError.invalidAudio }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.size] as? Int ?? 0

        if duration <= Self.singleCallMaxDuration && fileSize < Self.singleCallMaxFileSize {
            print("DiarizedTranscriptionService: single call (duration=\(Int(duration))s, size=\(fileSize / 1024)KB)")
            let segments = try await transcribeChunk(url: audioURL, startOffset: 0, speakerTagBase: speakerTagOffset)
            return segments.sorted { $0.startTime < $1.startTime }
        }

        print("DiarizedTranscriptionService: chunked path (duration=\(Int(duration))s, size=\(fileSize / 1024)KB)")

        let cuts: [(start: TimeInterval, end: TimeInterval)]
        do {
            cuts = try computeSilenceCuts(url: audioURL, duration: duration)
        } catch {
            print("DiarizedTranscriptionService: silence detection failed (\(error.localizedDescription)), using uniform cuts")
            cuts = uniformCuts(duration: duration)
        }

        // Unique temp directory per job to avoid /tmp/chunk_N.m4a collisions
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var allSegments: [TranscriptSegment] = []
        for (chunkIndex, cut) in cuts.enumerated() {
            let chunkURL = tempDir.appendingPathComponent("chunk_\(chunkIndex).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: cut.start, preferredTimescale: 44100),
                end: CMTime(seconds: cut.end, preferredTimescale: 44100)
            )
            do {
                try exportChunk(asset: asset, timeRange: range, to: chunkURL)
                // Each chunk gets a non-overlapping tag namespace so cross-chunk speaker labels
                // never collide before consolidateSpeakerTags reconciles them.
                let speakerBase = speakerTagOffset + chunkIndex * Self.speakerNamespaceStride
                let segments = try await transcribeChunk(url: chunkURL, startOffset: cut.start, speakerTagBase: speakerBase)
                allSegments.append(contentsOf: segments)
                print("DiarizedTranscriptionService: chunk \(chunkIndex + 1)/\(cuts.count) ok, \(segments.count) segments")
            } catch {
                print("DiarizedTranscriptionService: chunk \(chunkIndex + 1)/\(cuts.count) failed: \(error.localizedDescription)")
                // Partial transcript is better than nothing; continue with remaining chunks.
            }
        }

        guard !allSegments.isEmpty else {
            throw DiarizedError.transcriptionFailed("All \(cuts.count) chunks failed to transcribe")
        }

        return allSegments.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - API Call

    private func transcribeChunk(url: URL, startOffset: TimeInterval, speakerTagBase: Int) async throws -> [TranscriptSegment] {
        let audioData = try Data(contentsOf: url)
        guard !audioData.isEmpty else { return [] }

        guard let apiURL = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw DiarizedError.invalidConfig
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300  // 5 min for large chunks

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-transcribe-diarize\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("diarized_json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"chunking_strategy\"\r\n\r\n")
        append("auto\r\n")

        let ext = url.pathExtension.lowercased()
        let mimeType: String
        let filename: String
        switch ext {
        case "m4a": mimeType = "audio/mp4"; filename = "audio.m4a"
        case "mp3": mimeType = "audio/mpeg"; filename = "audio.mp3"
        case "mp4": mimeType = "audio/mp4"; filename = "audio.mp4"
        case "caf": mimeType = "audio/x-caf"; filename = "audio.caf"
        case "ogg", "oga": mimeType = "audio/ogg"; filename = "audio.ogg"
        case "flac": mimeType = "audio/flac"; filename = "audio.flac"
        case "webm": mimeType = "audio/webm"; filename = "audio.webm"
        default: mimeType = "audio/wav"; filename = "audio.wav"
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let requestID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id") ?? "unknown"

        guard let http = response as? HTTPURLResponse else {
            throw DiarizedError.transcriptionFailed("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw DiarizedError.transcriptionFailed("HTTP \(http.statusCode) (request-id: \(requestID)): \(msg)")
        }

        return try parseDiarizedResponse(data: data, startOffset: startOffset, speakerTagBase: speakerTagBase)
    }

    private func parseDiarizedResponse(data: Data, startOffset: TimeInterval, speakerTagBase: Int) throws -> [TranscriptSegment] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiarizedError.parseError("Response is not a JSON object")
        }

        guard let rawSegments = json["segments"] as? [[String: Any]] else {
            let topKeys = json.keys.sorted().joined(separator: ", ")
            throw DiarizedError.parseError("No 'segments' key in diarized_json response. Top-level keys: \(topKeys)")
        }

        // Map speaker label strings (e.g. "A", "speaker_1") to integer tags in first-seen order.
        var speakerMap: [String: Int] = [:]
        var nextTag = speakerTagBase

        func tagFor(_ label: String) -> Int {
            if let existing = speakerMap[label] { return existing }
            let tag = nextTag
            speakerMap[label] = tag
            nextTag += 1
            return tag
        }

        var result: [TranscriptSegment] = []
        var droppedCount = 0
        var droppedSample: String? = nil

        for seg in rawSegments {
            guard let text = seg["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let speakerLabel = seg["speaker"] as? String else {
                droppedCount += 1
                if droppedCount == 1 {
                    let keys = seg.keys.sorted().map { "\($0)=\(String(describing: seg[$0]!))" }.joined(separator: ", ")
                    droppedSample = keys
                }
                continue
            }

            // OpenAI audio timestamps are normally in seconds; the >= 10000 branch is a defensive fallback for millisecond values.
            let rawStart = seg["start"] as? Double ?? 0
            let rawEnd   = seg["end"]   as? Double ?? rawStart
            let start = (rawStart >= 10000 ? rawStart / 1000.0 : rawStart) + startOffset
            let end   = max((rawEnd >= 10000 ? rawEnd / 1000.0 : rawEnd) + startOffset, start + 0.01)

            result.append(TranscriptSegment(
                speakerTag: tagFor(speakerLabel),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: start,
                endTime: end
            ))
        }

        if droppedCount > 0 {
            print("DiarizedTranscriptionService: dropped \(droppedCount) segment(s) for missing/empty text or speaker; sample: \(droppedSample ?? "?")")
        }

        return result
    }

    // MARK: - Silence-Aware Chunking

    private func computeSilenceCuts(url: URL, duration: TimeInterval) throws -> [(start: TimeInterval, end: TimeInterval)] {
        let energyWindows = try computeRMSEnergy(url: url)
        guard !energyWindows.isEmpty else { return uniformCuts(duration: duration) }

        let windowDuration = Self.rmsWindowSeconds

        // Compute global noise reference (median energy) and derive silence threshold.
        let sorted = energyWindows.sorted()
        let medianEnergy = sorted[sorted.count / 2]
        let silenceThreshold = Self.silenceFactor * medianEnergy
        let minRunWindows = Int(ceil(Self.minSilenceRunSeconds / Self.rmsWindowSeconds))

        print("DiarizedTranscriptionService: silence detection — medianEnergy=\(String(format: "%.2e", medianEnergy)), threshold=\(String(format: "%.2e", silenceThreshold)), minRunWindows=\(minRunWindows)")

        var cuts: [(start: TimeInterval, end: TimeInterval)] = []
        var chunkStart: TimeInterval = 0
        var chunkIndex = 0

        while chunkStart < duration {
            let targetEnd = chunkStart + Self.chunkTargetDuration
            if targetEnd >= duration {
                cuts.append((chunkStart, duration))
                break
            }

            // Clamp search range: never cut before minChunkDuration into the chunk,
            // and never past duration.
            let searchFrom = max(chunkStart + Self.minChunkDuration, targetEnd - Self.silenceSearchWindow)
            let searchTo   = min(duration, targetEnd + Self.silenceSearchWindow)

            let fromIdx = max(0, Int(searchFrom / windowDuration))
            let toIdx   = min(energyWindows.count - 1, Int(searchTo / windowDuration))

            // Collect all qualifying silence runs (>= minRunWindows consecutive silent windows) in the search range.
            struct SilenceRun { let centerIdx: Int; let length: Int; let centerEnergy: Float }
            var silenceRuns: [SilenceRun] = []

            if fromIdx <= toIdx {
                var runStart: Int? = nil
                for i in fromIdx...toIdx {
                    if energyWindows[i] <= silenceThreshold {
                        if runStart == nil { runStart = i }
                    } else {
                        if let rs = runStart {
                            let runLen = i - rs
                            if runLen >= minRunWindows {
                                let centerIdx = rs + runLen / 2
                                silenceRuns.append(SilenceRun(centerIdx: centerIdx, length: runLen, centerEnergy: energyWindows[centerIdx]))
                            }
                            runStart = nil
                        }
                    }
                }
                // Close run that extends to the end of the search window.
                if let rs = runStart {
                    let runLen = toIdx + 1 - rs
                    if runLen >= minRunWindows {
                        let centerIdx = rs + runLen / 2
                        silenceRuns.append(SilenceRun(centerIdx: centerIdx, length: runLen, centerEnergy: energyWindows[centerIdx]))
                    }
                }
            }

            let targetIdx = Int(targetEnd / windowDuration)

            let cutTime: TimeInterval
            let logDetail: String
            if let bestRun = silenceRuns.min(by: { abs($0.centerIdx - targetIdx) < abs($1.centerIdx - targetIdx) }) {
                cutTime = TimeInterval(bestRun.centerIdx) * windowDuration
                logDetail = "silence run (len=\(bestRun.length) windows, energy=\(String(format: "%.2e", bestRun.centerEnergy)))"
            } else {
                // No qualifying silence run found — hard cut at target to stay within size limits.
                cutTime = targetEnd
                logDetail = "HARD CUT (no qualifying silence run in search window)"
            }

            let clampedCut = min(cutTime, duration)
            print("DiarizedTranscriptionService: chunk \(chunkIndex) boundary at \(String(format: "%.1f", clampedCut))s — \(logDetail)")
            cuts.append((chunkStart, clampedCut))
            chunkStart = clampedCut
            chunkIndex += 1
        }

        return cuts
    }

    /// Fallback: uniform time-based cuts when silence detection is unavailable.
    private func uniformCuts(duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var cuts: [(start: TimeInterval, end: TimeInterval)] = []
        var start: TimeInterval = 0
        while start < duration {
            let end = min(start + Self.chunkTargetDuration, duration)
            cuts.append((start, end))
            start = end
        }
        return cuts
    }

    /// Compute per-window mean-square energy across the entire audio file.
    /// Reads in blocks to avoid loading the whole file into memory.
    private func computeRMSEnergy(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = Int64(audioFile.length)

        let windowFrames = Int(sampleRate * Self.rmsWindowSeconds)
        guard windowFrames > 0 else { return [] }

        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
            return []
        }

        var windowEnergy: Float = 0
        var windowSampleCount = 0
        var result: [Float] = []

        audioFile.framePosition = 0
        while audioFile.framePosition < totalFrames {
            let remaining = totalFrames - audioFile.framePosition
            let toRead = AVAudioFrameCount(min(Int64(blockSize), remaining))
            buffer.frameLength = 0
            try audioFile.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            guard let floatData = buffer.floatChannelData else { continue }

            for frame in 0..<Int(buffer.frameLength) {
                var sampleEnergy: Float = 0
                for ch in 0..<channelCount {
                    let s = floatData[ch][frame]
                    sampleEnergy += s * s
                }
                windowEnergy += sampleEnergy / Float(channelCount)
                windowSampleCount += 1

                if windowSampleCount >= windowFrames {
                    result.append(windowEnergy / Float(windowFrames))
                    windowEnergy = 0
                    windowSampleCount = 0
                }
            }
        }

        // Flush partial final window
        if windowSampleCount > 0 {
            result.append(windowEnergy / Float(windowSampleCount))
        }

        return result
    }

    // MARK: - Chunk Export

    private func exportChunk(asset: AVURLAsset, timeRange: CMTimeRange, to outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DiarizedError.exportFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange

        let sema = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            sema.signal()
        }
        sema.wait()

        if let err = exportSession.error { throw err }
        guard exportSession.status == .completed else { throw DiarizedError.exportFailed }
    }
}

// MARK: - Errors

enum DiarizedError: LocalizedError {
    case invalidAudio
    case invalidConfig
    case exportFailed
    case transcriptionFailed(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "Audio file is empty or unreadable."
        case .invalidConfig: return "Invalid Diarized API configuration."
        case .exportFailed: return "Failed to export audio chunk."
        case .transcriptionFailed(let msg): return "Diarized transcription failed: \(msg)"
        case .parseError(let msg): return "Diarized transcription parse error: \(msg)"
        }
    }
}
