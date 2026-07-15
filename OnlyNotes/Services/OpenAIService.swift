import Foundation

class OpenAIService {
    private let apiKey: String
    private let webAnswerModel = "gpt-5.4-mini-2026-03-17"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Web Answer Synthesis

    func synthesizeWebAnswer(query: String, results: [ContextResult]) async throws -> WebAnswer {
        guard !apiKey.isEmpty else { throw OpenAIError.webSynthesisFailed("OpenAI API key not set") }
        guard !results.isEmpty else { throw OpenAIError.webSynthesisFailed("No search results to synthesize") }

        let numberedResults = results.enumerated().map { (i, result) -> String in
            let url: String
            if case .web(let u) = result.source { url = u } else { url = "" }
            return "[\(i + 1)] \(result.title)\nURL: \(url)\n\(result.snippet)"
        }.joined(separator: "\n\n")

        let systemPrompt = """
        You are a research assistant. Answer the user's query in 2-4 concise sentences using ONLY the supplied search results.
        Return a JSON object with this exact shape: {"answer": "<string>", "citations": [<1-based int indices of results used>]}
        If the results don't contain enough information, say so briefly in "answer" and return an empty citations array.
        """

        let userPrompt = "Query: \(query)\n\nSearch results:\n\(numberedResults)"

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": webAnswerModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIError.webSynthesisFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = chatResponse.choices.first?.message.content ?? ""

        guard let contentData = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            throw OpenAIError.webSynthesisFailed("Malformed response from model")
        }

        guard let answerText = json["answer"] as? String, !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.webSynthesisFailed("Model returned no answer")
        }

        let citationIndices: [Int] = json["citations"] as? [Int] ?? []

        var seenURLs = Set<String>()
        let citations: [WebAnswerCitation] = citationIndices.compactMap { idx in
            let i = idx - 1
            guard i >= 0, i < results.count else { return nil }
            guard case .web(let url) = results[i].source else { return nil }
            guard seenURLs.insert(url).inserted else { return nil }
            return WebAnswerCitation(title: results[i].title, url: url)
        }

        return WebAnswer(text: answerText, citations: citations)
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

    /// Consolidates redundant speaker IDs in a transcript by asking GPT-4o to identify which
    /// speaker IDs refer to the same real person (AssemblyAI often over-fragments). Only
    /// `speakerTag` values are modified — id, text, startTime, endTime, and ordering are preserved.
    /// `protectedTags` are never used as either side of a remap. Callers should always include 0
    /// (warning markers); dual-track recording flows should also include 1 (mic speaker) to keep
    /// it isolated from the system-audio track before they are merged.
    /// Fail-open: returns the input segments unchanged on any API/parse error.
    func consolidateSpeakerTags(_ segments: [TranscriptSegment], protectedTags: Set<Int> = [0]) async -> [TranscriptSegment] {
        guard !segments.isEmpty, !apiKey.isEmpty else { return segments }

        // Build payload — skip protected tags so we don't ask the model to remap them, but they
        // stay present in the output.
        let candidates = segments.enumerated().compactMap { (i, seg) -> [String: Any]? in
            guard !protectedTags.contains(seg.speakerTag) else { return nil }
            let truncatedText = seg.text.count > 200 ? String(seg.text.prefix(200)) + "…" : seg.text
            return ["index": i, "speaker_id": seg.speakerTag, "text": truncatedText] as [String: Any]
        }
        guard candidates.count >= 2 else { return segments }
        let uniqueTags = Set(candidates.compactMap { $0["speaker_id"] as? Int })
        guard uniqueTags.count >= 2 else { return segments }

        let systemPrompt = """
        You are a speaker diarization cleanup assistant. The transcript below has speaker IDs from an automatic system that sometimes splits ONE real person across multiple speaker IDs (especially at the start of recordings or across short utterances).

        Your task: identify speaker IDs that refer to the SAME real person and return a remap.

        Strong signals that two IDs are the SAME person:
        - One ID's segment ends mid-sentence without punctuation, the next ID's segment is a clear continuation
        - The same ID-pair alternates rapidly through what is clearly one continuous thought
        - Short fragments (one or two words) bookended by the same person's content

        Strong signals that two IDs are DIFFERENT people:
        - One person addresses another by name and gets a reply
        - Clear Q→A turn structure with semantic shift
        - Different roles in the conversation (host vs guest, presenter vs audience)

        Be conservative. Only merge when evidence is strong. Preserving real distinct speakers matters more than over-consolidating.

        Return JSON in this exact format:
        {"remap": {"<old_id>": <new_id>, ...}}

        Only include entries where old_id != new_id. If no consolidation is needed, return {"remap": {}}.
        The new_id values must be integers chosen from the existing speaker_id set in the input.
        """

        guard let userJSON = try? JSONSerialization.data(withJSONObject: ["segments": candidates]),
              let userText = String(data: userJSON, encoding: .utf8) else {
            return segments
        }

        let payload: [String: Any] = [
            "model": "gpt-4o",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return segments
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let chatResp = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = chatResp.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let remapRaw = parsed["remap"] as? [String: Any]
        else {
            print("OpenAIService: consolidateSpeakerTags failed, returning segments unchanged")
            return segments
        }

        // Validate the remap: keys/values must be integers, both must be in the original tag set
        // (we never invent new speakers), neither side may be a protected tag, and no-op remaps
        // are dropped.
        var remap: [Int: Int] = [:]
        for (key, value) in remapRaw {
            guard let oldID = Int(key), let newID = value as? Int else { continue }
            guard !protectedTags.contains(oldID), !protectedTags.contains(newID) else { continue }
            guard uniqueTags.contains(oldID), uniqueTags.contains(newID) else { continue }
            guard oldID != newID else { continue }
            remap[oldID] = newID
        }

        // Resolve transitive merges (a→b, b→c becomes a→c). Bounded iterations to avoid cycles.
        for _ in 0..<8 {
            var changed = false
            for (old, new) in remap {
                if let next = remap[new], next != new {
                    remap[old] = next
                    changed = true
                }
            }
            if !changed { break }
        }

        guard !remap.isEmpty else { return segments }

        return segments.map { seg in
            guard let newTag = remap[seg.speakerTag] else { return seg }
            var s = seg
            s.speakerTag = newTag
            return s
        }
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
    case webSynthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .summarizationFailed(let msg): return "Summarization failed: \(msg)"
        case .chatFailed(let msg): return "Chat failed: \(msg)"
        case .controlChatFailed(let msg): return "Control chat failed: \(msg)"
        case .webSynthesisFailed(let msg): return "Web answer synthesis failed: \(msg)"
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
