import Foundation

private struct NotesFile: Codable {
    var schemaVersion: Int
    var notes: [Note]
}

class NoteStore {
    static let shared = NoteStore()

    private(set) var migrationError: String? = nil
    private(set) var loadError: String? = nil

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    private var legacyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes", isDirectory: true)
        return dir.appendingPathComponent("meetings.json")
    }

    private var backupURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes", isDirectory: true)
        return dir.appendingPathComponent("meetings.backup.json")
    }

    /// Call once at app launch before any other store operations.
    func migrateIfNeeded() {
        // If notes.json exists and is already current schema, skip
        if let data = try? Data(contentsOf: storageURL),
           let file = try? JSONDecoder().decode(NotesFile.self, from: data),
           file.schemaVersion >= 1 {
            return
        }

        // No legacy data — fresh install, just initialize
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL) else {
            return
        }

        // Backup legacy file — log if backup fails but continue
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: legacyURL, to: backupURL)
        } catch {
            print("NoteStore: WARNING — backup of meetings.json failed: \(error). Aborting migration to protect data.")
            migrationError = "Could not back up meetings.json before migration. No data was changed."
            return
        }

        // Decode legacy meetings
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacyMeetings = try? decoder.decode([LegacyMeeting].self, from: data) else {
            print("NoteStore: could not decode legacy meetings.json — aborting migration, data untouched")
            migrationError = "Could not read meetings.json. Your old data is safe but was not migrated."
            return
        }

        // Convert and persist as versioned notes.json
        let notes = legacyMeetings.map { Note(fromLegacy: $0) }
        persist(notes)
        print("NoteStore: migrated \(notes.count) meetings → notes.json (schema v1)")
    }

    func loadAll() -> [Note] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(NotesFile.self, from: data) {
            loadError = nil
            return file.notes
        }
        loadError = "Could not read notes data. File may be corrupted."
        return []
    }

    func save(_ note: Note) {
        var normalized = note
        normalized.setTags(note.tags)
        var notes = loadAll()
        if let idx = notes.firstIndex(where: { $0.id == normalized.id }) {
            notes[idx] = normalized
        } else {
            notes.insert(normalized, at: 0)
        }
        persist(notes)
    }

    func delete(_ note: Note) {
        var notes = loadAll()
        notes.removeAll { $0.id == note.id }
        persist(notes)
        EmbeddingService.shared.removeNote(id: note.id)
        if let path = note.meetingAttachment?.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func persist(_ notes: [Note]) {
        let file = NotesFile(schemaVersion: 1, notes: notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

// MARK: - Legacy migration types

private struct LegacyMeeting: Codable {
    let id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment]
    var speakers: [String: String]
    var summary: String
    var actionItems: [String]
    var chatMessages: [LegacyChatMessage]
    var audioFilePath: String?
    var notes: [MeetingNote]

    enum CodingKeys: String, CodingKey {
        case id, title, date, duration, segments, speakers, summary, actionItems, chatMessages, audioFilePath, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        segments = (try? c.decode([TranscriptSegment].self, forKey: .segments)) ?? []
        speakers = (try? c.decode([String: String].self, forKey: .speakers)) ?? [:]
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        actionItems = (try? c.decode([String].self, forKey: .actionItems)) ?? []
        chatMessages = (try? c.decode([LegacyChatMessage].self, forKey: .chatMessages)) ?? []
        audioFilePath = try? c.decodeIfPresent(String.self, forKey: .audioFilePath)
        notes = (try? c.decodeIfPresent([MeetingNote].self, forKey: .notes)) ?? []
    }
}

/// Legacy ChatMessage with enum role and timestamp — decodes old JSON format.
private struct LegacyChatMessage: Codable {
    let id: UUID
    let role: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case id, role, content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // role was stored as "user"/"assistant" string (enum rawValue) — decode as String
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
    }
}

private extension Note {
    init(fromLegacy m: LegacyMeeting) {
        self.id = m.id
        self.title = m.title
        self.body = ""
        self.tags = []
        self.createdAt = m.date
        self.updatedAt = m.date
        self.meetingAttachment = MeetingAttachment(
            segments: m.segments,
            speakers: m.speakers,
            summary: m.summary,
            actionItems: m.actionItems,
            chatMessages: m.chatMessages.map { ChatMessage(id: $0.id, role: $0.role, content: $0.content) },
            duration: m.duration,
            audioFilePath: m.audioFilePath,
            notes: m.notes
        )
    }
}
