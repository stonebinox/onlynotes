import Foundation

// MARK: - Note (top-level entity)

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var body: String                          // freeform typed content
    var tags: [String]                        // normalized: trimmed, lowercased, deduped
    var createdAt: Date
    var updatedAt: Date
    var meetingAttachment: MeetingAttachment? // nil for plain notes

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        meetingAttachment: MeetingAttachment? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.meetingAttachment = meetingAttachment
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, tags, createdAt, updatedAt, meetingAttachment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
        meetingAttachment = try? c.decodeIfPresent(MeetingAttachment.self, forKey: .meetingAttachment)
    }

    var isMeetingNote: Bool { meetingAttachment != nil }

    /// Normalize and set tags: trim, lowercase, dedupe, remove empty
    mutating func setTags(_ raw: [String]) {
        var seen = Set<String>()
        tags = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - MeetingAttachment

struct MeetingAttachment: Codable, Hashable {
    var segments: [TranscriptSegment]
    var speakers: [String: String]     // speakerTag (as string) -> display name
    var summary: String
    var actionItems: [String]
    var chatMessages: [ChatMessage]
    var duration: TimeInterval
    var audioFilePath: String?
    var notes: [MeetingNote]           // live timestamp notes captured during recording

    init(
        segments: [TranscriptSegment] = [],
        speakers: [String: String] = [:],
        summary: String = "",
        actionItems: [String] = [],
        chatMessages: [ChatMessage] = [],
        duration: TimeInterval = 0,
        audioFilePath: String? = nil,
        notes: [MeetingNote] = []
    ) {
        self.segments = segments
        self.speakers = speakers
        self.summary = summary
        self.actionItems = actionItems
        self.chatMessages = chatMessages
        self.duration = duration
        self.audioFilePath = audioFilePath
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case segments, speakers, summary, actionItems, chatMessages, duration, audioFilePath, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = (try? c.decodeIfPresent([TranscriptSegment].self, forKey: .segments)) ?? []
        speakers = (try? c.decodeIfPresent([String: String].self, forKey: .speakers)) ?? [:]
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        actionItems = (try? c.decodeIfPresent([String].self, forKey: .actionItems)) ?? []
        chatMessages = (try? c.decodeIfPresent([ChatMessage].self, forKey: .chatMessages)) ?? []
        duration = (try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? 0
        audioFilePath = try? c.decodeIfPresent(String.self, forKey: .audioFilePath)
        notes = (try? c.decodeIfPresent([MeetingNote].self, forKey: .notes)) ?? []
    }

    /// Flat transcript for display/AI, resolving speaker names
    func transcript(resolvingNames: Bool = true) -> String {
        segments.map { segment in
            let name = resolvingNames
                ? (speakers[String(segment.speakerTag)] ?? "Speaker \(segment.speakerTag)")
                : "Speaker \(segment.speakerTag)"
            return "\(name): \(segment.text)"
        }.joined(separator: "\n")
    }
}

// MARK: - MeetingNote (live timestamp notes during recording)

struct MeetingNote: Identifiable, Codable, Hashable {
    let id: UUID
    let timestampOffset: TimeInterval
    var text: String

    init(id: UUID = UUID(), timestampOffset: TimeInterval, text: String) {
        self.id = id
        self.timestampOffset = timestampOffset
        self.text = text
    }

    var formattedTimestamp: String {
        let m = Int(timestampOffset) / 60
        let s = Int(timestampOffset) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: String   // "user" or "assistant"
    var content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
