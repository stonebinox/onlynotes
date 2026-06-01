import Foundation

class OpenAIService {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Summarization

    func summarize(segments: [TranscriptSegment], speakers: [String: String], notes: [MeetingNote] = []) async throws -> SummaryResult {
        let transcript = segments.map { segment in
            let name = speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)"
            return "\(name): \(segment.text)"
        }.joined(separator: "\n")

        var fullPromptText = transcript
        if !notes.isEmpty {
            let notesBlock = notes.map { "\($0.formattedTimestamp) - \($0.text)" }.joined(separator: "\n")
            fullPromptText += "\n\nUser Notes (timestamps are relative to recording start):\n\(notesBlock)\n\nUse these notes as context for the user's intent and focus areas during the meeting. Do not invent facts not present in the transcript."
        }

        return try await summarizeTranscript(fullPromptText)
    }

    private func summarizeTranscript(_ transcript: String) async throws -> SummaryResult {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Summarize this meeting transcript. Return JSON with:
        - "title": a short descriptive title (5-8 words)
        - "summary": a concise paragraph summary
        - "actionItems": an array of action item strings

        Transcript:
        \(transcript)
        """

        let payload: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "You are a meeting notes assistant. Always respond with valid JSON."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenAIError.summarizationFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw OpenAIError.summarizationFailed("Empty response")
        }

        return try JSONDecoder().decode(SummaryResult.self, from: jsonData)
    }

    // MARK: - AI Chat

    func chat(messages: [ChatMessage], transcript: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are an assistant helping the user understand a meeting they just had. \
        Answer questions about the meeting based on the transcript below. Be concise and helpful.

        Meeting Transcript:
        \(transcript)
        """

        var apiMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        let payload: [String: Any] = [
            "model": "gpt-4o",
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenAIError.chatFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        return chatResponse.choices.first?.message.content ?? ""
    }

    func chatWithMeetingControl(
        messages: [ChatMessage],
        transcript: String,
        speakers: [String: String],
        tags: [String],
        hasAudio: Bool,
        hasTranscript: Bool
    ) async throws -> MeetingControlResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let speakersDesc = speakers.isEmpty ? "none" : speakers.map { "Speaker \($0.key): \($0.value)" }.joined(separator: ", ")
        let tagsDesc = tags.isEmpty ? "none" : tags.joined(separator: ", ")

        let systemPrompt = """
        You are an assistant for a meeting notes app. You can answer questions about the meeting OR take one of the following actions when explicitly requested by the user.

        When taking an action, respond with JSON: { "mode": "action", "assistantMessage": "<user-friendly confirmation>", "action": { "type": "<type>", <args> } }
        When answering a question, respond with JSON: { "mode": "answer", "assistantMessage": "<your answer>", "action": null }

        Available actions:
        - retranscribe: Re-run speech-to-text on the audio file. Args: none. Only available when hasAudio is true.
        - regenerate_summary: Regenerate the meeting summary. Args: { "context": "<optional user context string>" }
        - rename_speaker: Rename a speaker. Args: { "speakerTag": <int>, "newName": "<string>" }
        - add_tag: Add a tag to this note. Args: { "tag": "<string>" }
        - remove_tag: Remove a tag. Args: { "tag": "<string>" }
        - translate: Translate the entire transcript to a target language. Rewrites all segments. Args: { "targetLanguage": "<language name, e.g. English>" }

        Current meeting context:
        - Has audio: \(hasAudio)
        - Has transcript: \(hasTranscript)
        - Current tags: \(tagsDesc)
        - Speaker names: \(speakersDesc)

        Meeting transcript:
        \(transcript.isEmpty ? "(no transcript available)" : transcript)
        """

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        let historyMessages = messages.dropLast()
        for msg in historyMessages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }
        if let lastMsg = messages.last {
            apiMessages.append(["role": lastMsg.role, "content": lastMsg.content])
        }

        let payload: [String: Any] = [
            "model": "gpt-4o",
            "messages": apiMessages,
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenAIError.controlChatFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content else {
            return MeetingControlResponse(mode: "answer", assistantMessage: "No response received.", action: nil)
        }

        guard let jsonData = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let mode = json["mode"] as? String,
              let assistantMessage = json["assistantMessage"] as? String else {
            return MeetingControlResponse(mode: "answer", assistantMessage: content, action: nil)
        }

        var meetingAction: MeetingAction? = nil
        if mode == "action", let actionDict = json["action"] as? [String: Any],
           let actionType = actionDict["type"] as? String {
            meetingAction = MeetingAction(
                type: actionType,
                speakerTag: actionDict["speakerTag"] as? Int,
                newName: actionDict["newName"] as? String,
                tag: actionDict["tag"] as? String,
                context: actionDict["context"] as? String,
                targetLanguage: actionDict["targetLanguage"] as? String
            )
        }

        return MeetingControlResponse(mode: mode, assistantMessage: assistantMessage, action: meetingAction)
    }

    func translateSegments(_ segments: [TranscriptSegment], to language: String) async throws -> [TranscriptSegment] {
        var translated: [TranscriptSegment] = []

        // Process in batches of 30 segments to stay within token limits
        let batchSize = 30
        for batchStart in stride(from: 0, to: segments.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<batchEnd])

            let textsJSON = batch.enumerated().map { (i, seg) in
                ["index": i, "text": seg.text] as [String: Any]
            }

            guard let textsData = try? JSONSerialization.data(withJSONObject: textsJSON),
                  let textsString = String(data: textsData, encoding: .utf8) else {
                throw OpenAIError.chatFailed("Failed to serialize segments for translation")
            }

            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            let prompt = """
            Translate each text segment to \(language). Return a JSON object with a "translations" key containing an array:
            {"translations": [{"index": 0, "text": "translated text"}, ...]}
            Preserve the index values exactly. Only translate the text, nothing else.

            Segments:
            \(textsString)
            """

            let payload: [String: Any] = [
                "model": "gpt-4o",
                "messages": [
                    ["role": "system", "content": "You are a translator. Return only valid JSON arrays."],
                    ["role": "user", "content": prompt]
                ],
                "response_format": ["type": "json_object"]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OpenAIError.chatFailed("Translation HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = chatResponse.choices.first?.message.content,
                  let jsonData = content.data(using: .utf8) else {
                throw OpenAIError.chatFailed("Empty translation response")
            }

            // Parse — response_format json_object wraps in an object, so handle both array and object
            let translatedTexts: [[String: Any]]
            if let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                translatedTexts = arr
            } else if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let arr = obj["translations"] as? [[String: Any]] ?? obj["segments"] as? [[String: Any]] ?? obj["results"] as? [[String: Any]] {
                translatedTexts = arr
            } else {
                throw OpenAIError.chatFailed("Could not parse translation response")
            }

            // Build lookup by index
            var textByIndex: [Int: String] = [:]
            for item in translatedTexts {
                if let idx = item["index"] as? Int, let text = item["text"] as? String {
                    textByIndex[idx] = text
                }
            }

            for (i, seg) in batch.enumerated() {
                var s = seg
                if let translatedText = textByIndex[i] {
                    s.text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                translated.append(s)
            }
        }

        return translated
    }
}

// MARK: - Models

struct SummaryResult: Codable {
    let title: String
    let summary: String
    let actionItems: [String]
}

struct ChatResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String?
    }
}

enum OpenAIError: LocalizedError {
    case summarizationFailed(String)
    case chatFailed(String)
    case controlChatFailed(String)

    var errorDescription: String? {
        switch self {
        case .summarizationFailed(let msg): return "Summarization failed: \(msg)"
        case .chatFailed(let msg): return "Chat failed: \(msg)"
        case .controlChatFailed(let msg): return "Control chat failed: \(msg)"
        }
    }
}

struct MeetingControlResponse {
    let mode: String
    let assistantMessage: String
    let action: MeetingAction?
}

struct MeetingAction {
    let type: String
    let speakerTag: Int?
    let newName: String?
    let tag: String?
    let context: String?
    let targetLanguage: String?
}
