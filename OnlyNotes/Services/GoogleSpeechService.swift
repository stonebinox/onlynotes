import Foundation

class GoogleSpeechService {
    private let apiKey: String
    private let serviceAccountKeyPath: String

    init(apiKey: String, serviceAccountKeyPath: String) {
        self.apiKey = apiKey
        self.serviceAccountKeyPath = serviceAccountKeyPath
    }

    /// Transcribe an audio file via GCS upload + longrunningrecognize.
    func transcribe(audioURL: URL, bucket: String) async throws -> [TranscriptSegment] {
        let filename = audioURL.lastPathComponent
        var uploaded = false

        defer {
            if uploaded {
                Task { await self.deleteFromGCS(bucket: bucket, filename: filename) }
            }
        }

        try await uploadToGCS(audioURL: audioURL, bucket: bucket, filename: filename)
        uploaded = true
        let gcsURI = "gs://\(bucket)/\(filename)"
        let operationName = try await startLongRunningRecognize(gcsURI: gcsURI)
        let results = try await pollUntilDone(operationName: operationName)
        return parseSegments(from: results)
    }

    // MARK: - GCS Upload

    private func uploadToGCS(audioURL: URL, bucket: String, filename: String) async throws {
        let audioData = try Data(contentsOf: audioURL)

        guard let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let requestURL = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o?uploadType=media&name=\(encodedFilename)") else {
            throw GoogleSpeechError.invalidConfig
        }

        let token = try await GCSAuthService.shared.accessToken(serviceAccountKeyPath: serviceAccountKeyPath)

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // Token may be stale — invalidate and retry once
            await GCSAuthService.shared.invalidate()
            let freshToken = try await GCSAuthService.shared.accessToken(serviceAccountKeyPath: serviceAccountKeyPath)
            var retryRequest = request
            retryRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let http = retryResponse as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: retryData, encoding: .utf8) ?? "Unknown error"
                throw GoogleSpeechError.uploadFailed(body)
            }
            return
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleSpeechError.uploadFailed(body)
        }
    }

    // MARK: - GCS Delete

    private func deleteFromGCS(bucket: String, filename: String) async {
        guard !serviceAccountKeyPath.isEmpty,
              let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let requestURL = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedFilename)") else {
            print("GoogleSpeechService: could not build delete URL for \(filename)")
            return
        }

        guard let token = try? await GCSAuthService.shared.accessToken(serviceAccountKeyPath: serviceAccountKeyPath) else {
            print("GoogleSpeechService: could not get auth token for GCS delete")
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    print("GoogleSpeechService: GCS object not found (already deleted?) for \(filename)")
                } else if httpResponse.statusCode >= 300 {
                    print("GoogleSpeechService: GCS delete returned status \(httpResponse.statusCode) for \(filename)")
                }
            }
        } catch {
            print("GoogleSpeechService: GCS delete failed for \(filename): \(error)")
        }
    }

    // MARK: - Long-Running Recognize

    private func startLongRunningRecognize(gcsURI: String) async throws -> String {
        guard let requestURL = URL(string: "https://speech.googleapis.com/v1/speech:longrunningrecognize?key=\(apiKey)") else {
            throw GoogleSpeechError.invalidConfig
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": 16000,
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
                "uri": gcsURI
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleSpeechError.transcriptionFailed(body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            throw GoogleSpeechError.transcriptionFailed("Missing operation name in response")
        }

        return name
    }

    // MARK: - Polling

    private func pollUntilDone(operationName: String) async throws -> [[String: Any]] {
        guard let requestURL = URL(string: "https://speech.googleapis.com/v1/operations/\(operationName)?key=\(apiKey)") else {
            throw GoogleSpeechError.invalidConfig
        }

        let maxPolls = 180  // 15 minutes at 5s interval
        for _ in 0..<maxPolls {
            try await Task.sleep(nanoseconds: 5_000_000_000)

            let (data, response) = try await URLSession.shared.data(from: requestURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw GoogleSpeechError.transcriptionFailed(body)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let done = json["done"] as? Bool ?? false
            guard done else { continue }

            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown transcription error"
                throw GoogleSpeechError.transcriptionFailed(message)
            }

            if let responseObj = json["response"] as? [String: Any],
               let results = responseObj["results"] as? [[String: Any]] {
                return results
            }

            return []
        }

        throw GoogleSpeechError.transcriptionFailed("Transcription timed out after 15 minutes")
    }

    // MARK: - Response Parsing

    private func parseSegments(from results: [[String: Any]]) -> [TranscriptSegment] {
        guard let lastResult = results.last,
              let alternatives = lastResult["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let words = firstAlt["words"] as? [[String: Any]] else {
            return []
        }

        return groupWordsIntoSegments(words)
    }

    private func groupWordsIntoSegments(_ words: [[String: Any]]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentSpeaker = 0
        var currentWords: [String] = []
        var segmentStart: TimeInterval = 0
        var segmentEnd: TimeInterval = 0

        for wordData in words {
            guard let word = wordData["word"] as? String else { continue }
            let speakerTag = wordData["speakerTag"] as? Int ?? 1
            let startTime = parseTime(wordData["startTime"] as? String ?? "0s")
            let endTime = parseTime(wordData["endTime"] as? String ?? "0s")

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
}


enum GoogleSpeechError: LocalizedError {
    case invalidConfig
    case uploadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "Invalid Google Speech API configuration."
        case .uploadFailed(let msg): return "GCS upload failed: \(msg)"
        case .transcriptionFailed(let msg): return "Google Speech transcription failed: \(msg)"
        }
    }
}
