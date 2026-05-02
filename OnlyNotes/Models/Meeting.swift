import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment]      // speaker-labeled transcript from Google STT
    var speakers: [String: String]         // speakerTag (as string) -> display name, e.g. "1" -> "David"
    var summary: String
    var actionItems: [String]
    var chatMessages: [ChatMessage]
    var audioFilePath: String?

    // Flat transcript for display/AI, resolving speaker names
    func transcript(resolvingNames: Bool = true) -> String {
        segments.map { segment in
            let name = resolvingNames
                ? (speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)")
                : "Speaker \(segment.speakerTag)"
            return "\(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    init(
        id: UUID = UUID(),
        title: String = "Untitled Meeting",
        date: Date = Date(),
        duration: TimeInterval = 0,
        segments: [TranscriptSegment] = [],
        speakers: [String: String] = [:],
        summary: String = "",
        actionItems: [String] = [],
        chatMessages: [ChatMessage] = [],
        audioFilePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.segments = segments
        self.speakers = speakers
        self.summary = summary
        self.actionItems = actionItems
        self.chatMessages = chatMessages
        self.audioFilePath = audioFilePath
    }
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: Role
    var content: String
    var timestamp: Date

    enum Role: String, Codable {
        case user, assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
