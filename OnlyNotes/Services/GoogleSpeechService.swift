import AVFoundation
import Foundation

class GoogleSpeechService {
    private let apiKey: String
    private let chunkDuration: TimeInterval = 50  // seconds per chunk, safely under 60s sync limit

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Transcribe an audio file, returning speaker-labeled segments.
    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        let chunks = try splitIntoChunks(url: audioURL)
        var allSegments: [TranscriptSegment] = []

        for (chunkURL, timeOffset) in chunks {
            let segments = try await transcribeChunk(url: chunkURL, timeOffset: timeOffset)
            allSegments.append(contentsOf: segments)
            try? FileManager.default.removeItem(at: chunkURL)
        }

        return allSegments
    }

    // MARK: - Chunking

    private func splitIntoChunks(url: URL) throws -> [(URL, TimeInterval)] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        let framesPerChunk = AVAudioFrameCount(chunkDuration * format.sampleRate)

        var chunks: [(URL, TimeInterval)] = []
        var frameOffset: AVAudioFrameCount = 0

        while frameOffset < totalFrames {
            let framesToRead = min(framesPerChunk, totalFrames - frameOffset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else { break }

            file.framePosition = AVAudioFramePosition(frameOffset)
            try file.read(into: buffer, frameCount: framesToRead)

            let timeOffset = Double(frameOffset) / format.sampleRate
            let chunkURL = Self.tempChunkURL()
            let chunkFile = try AVAudioFile(
                forWriting: chunkURL,
                settings: AudioRecorder.wavSettings(sampleRate: format.sampleRate),
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try chunkFile.write(from: buffer)
            chunks.append((chunkURL, timeOffset))
            frameOffset += framesToRead
        }

        return chunks
    }

    // MARK: - Single Chunk Transcription

    private func transcribeChunk(url: URL, timeOffset: TimeInterval) async throws -> [TranscriptSegment] {
        let audioData = try Data(contentsOf: url)

        // Determine sample rate from the file
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = Int(audioFile.processingFormat.sampleRate)

        let endpoint = "https://speech.googleapis.com/v1/speech:recognize?key=\(apiKey)"
        guard let requestURL = URL(string: endpoint) else {
            throw GoogleSpeechError.invalidConfig
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": sampleRate,
                "languageCode": "en-US",
                "alternativeLanguageCodes": ["kn-IN", "ta-IN"],
                "diarizationConfig": [
                    "enableSpeakerDiarization": true,
                    "minSpeakerCount": 1,
                    "maxSpeakerCount": 6
                ],
                "model": "latest_long",
                "enableAutomaticPunctuation": true,
                "enableWordTimeOffsets": true
            ],
            "audio": [
                "content": audioData.base64EncodedString()
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleSpeechError.transcriptionFailed(msg)
        }

        return try parseSegments(from: data, timeOffset: timeOffset)
    }

    // MARK: - Response Parsing

    private func parseSegments(from data: Data, timeOffset: TimeInterval) throws -> [TranscriptSegment] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        // Speaker-labeled words are in the LAST result per Google's diarization docs
        guard let lastResult = results.last,
              let alternatives = lastResult["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let words = firstAlt["words"] as? [[String: Any]] else {
            return []
        }

        return groupWordsIntoSegments(words, timeOffset: timeOffset)
    }

    private func groupWordsIntoSegments(_ words: [[String: Any]], timeOffset: TimeInterval) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentSpeaker = 0
        var currentWords: [String] = []
        var segmentStart: TimeInterval = 0
        var segmentEnd: TimeInterval = 0

        for wordData in words {
            guard let word = wordData["word"] as? String else { continue }
            let speakerTag = wordData["speakerTag"] as? Int ?? 1
            let startTime = parseTime(wordData["startTime"] as? String ?? "0s") + timeOffset
            let endTime = parseTime(wordData["endTime"] as? String ?? "0s") + timeOffset

            if speakerTag != currentSpeaker && !currentWords.isEmpty {
                segments.append(TranscriptSegment(
                    speakerTag: currentSpeaker,
                    text: currentWords.joined(separator: " "),
                    startTime: segmentStart,
                    endTime: segmentEnd
                ))
                currentWords = []
            }

            if currentWords.isEmpty {
                currentSpeaker = speakerTag
                segmentStart = startTime
            }
            currentWords.append(word)
            segmentEnd = endTime
        }

        if !currentWords.isEmpty {
            segments.append(TranscriptSegment(
                speakerTag: currentSpeaker,
                text: currentWords.joined(separator: " "),
                startTime: segmentStart,
                endTime: segmentEnd
            ))
        }

        return segments
    }

    private func parseTime(_ str: String) -> TimeInterval {
        TimeInterval(str.replacingOccurrences(of: "s", with: "")) ?? 0
    }

    private static func tempChunkURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("onlynotes_chunk_\(UUID().uuidString).wav")
    }
}


enum GoogleSpeechError: LocalizedError {
    case invalidConfig
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "Invalid Google Speech API configuration."
        case .transcriptionFailed(let msg): return "Google Speech transcription failed: \(msg)"
        }
    }
}
