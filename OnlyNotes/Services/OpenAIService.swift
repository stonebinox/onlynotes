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
            apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
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

    var errorDescription: String? {
        switch self {
        case .summarizationFailed(let msg): return "Summarization failed: \(msg)"
        case .chatFailed(let msg): return "Chat failed: \(msg)"
        }
    }
}
