import Foundation

class MeetingStore {
    static let shared = MeetingStore()

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetings.json")
    }

    func loadAll() -> [Meeting] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? JSONDecoder().decode([Meeting].self, from: data)) ?? []
    }

    func save(_ meeting: Meeting) {
        var meetings = loadAll()
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        persist(meetings)
    }

    func delete(_ meeting: Meeting) {
        var meetings = loadAll()
        meetings.removeAll { $0.id == meeting.id }
        persist(meetings)

        // Clean up audio file
        if let path = meeting.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func persist(_ meetings: [Meeting]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(meetings) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
