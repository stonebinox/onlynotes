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
