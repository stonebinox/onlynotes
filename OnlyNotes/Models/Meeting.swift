import Foundation

struct MeetingNote: Identifiable, Codable, Hashable {
    let id: UUID
    let timestampOffset: TimeInterval  // seconds from recording start
    var text: String

    init(id: UUID = UUID(), timestampOffset: TimeInterval, text: String) {
        self.id = id
        self.timestampOffset = timestampOffset
        self.text = text
    }

    /// Formatted as "mm:ss"
    var formattedTimestamp: String {
        let m = Int(timestampOffset) / 60
        let s = Int(timestampOffset) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

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
    var notes: [MeetingNote]

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
        audioFilePath: String? = nil,
        notes: [MeetingNote] = []
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
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, title, date, duration, segments, speakers, summary, actionItems, chatMessages, audioFilePath, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        speakers = try c.decode([String: String].self, forKey: .speakers)
        summary = try c.decode(String.self, forKey: .summary)
        actionItems = try c.decode([String].self, forKey: .actionItems)
        chatMessages = try c.decode([ChatMessage].self, forKey: .chatMessages)
        audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
        notes = try c.decodeIfPresent([MeetingNote].self, forKey: .notes) ?? []
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
