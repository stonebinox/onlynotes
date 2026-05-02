import Foundation
import CommonCrypto

class EmbeddingService {
    static let shared = EmbeddingService()

    private let apiBase = "https://api.openai.com/v1/embeddings"
    private let model = "text-embedding-3-small"

    // MARK: - Embedding storage

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("embeddings.json")
    }

    private struct EmbeddingRecord: Codable {
        let noteID: UUID
        let digest: String        // hash of title+body to detect staleness
        let vector: [Float]
        let updatedAt: Date
    }

    private func loadIndex() -> [String: EmbeddingRecord] {
        guard let data = try? Data(contentsOf: storageURL),
              let index = try? JSONDecoder().decode([String: EmbeddingRecord].self, from: data)
        else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: EmbeddingRecord]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func digest(for note: Note) -> String {
        var content = "\(note.title)\n\(note.body)"
        if let attachment = note.meetingAttachment {
            content += "\n\(attachment.summary)"
            content += "\n" + attachment.segments.prefix(50).map { $0.text }.joined(separator: " ")
        }
        let data = Data(content.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Embedding fetch

    private func fetchEmbedding(for text: String, apiKey: String) async throws -> [Float] {
        guard let url = URL(string: apiBase) else { throw EmbeddingError.invalidConfig }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "input": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first,
              let embedding = first["embedding"] as? [Double]
        else { throw EmbeddingError.badResponse }
        return embedding.map { Float($0) }
    }

    // MARK: - Index update

    /// Ensure the given note has a fresh embedding in the index. No-op if digest matches.
    func indexNote(_ note: Note, apiKey: String) async {
        guard !apiKey.isEmpty else { return }
        var parts: [String] = []
        if !note.title.isEmpty { parts.append(note.title) }
        if !note.body.isEmpty { parts.append(note.body) }
        if let attachment = note.meetingAttachment {
            if !attachment.summary.isEmpty { parts.append(attachment.summary) }
            let transcriptSnippet = attachment.segments.prefix(100).map { $0.text }.joined(separator: " ")
            if !transcriptSnippet.isEmpty { parts.append(transcriptSnippet) }
        }
        let content = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let d = digest(for: note)
        var index = loadIndex()
        if let existing = index[note.id.uuidString], existing.digest == d { return }
        guard let vector = try? await fetchEmbedding(for: content, apiKey: apiKey) else { return }
        index[note.id.uuidString] = EmbeddingRecord(noteID: note.id, digest: d, vector: vector, updatedAt: Date())
        saveIndex(index)
    }

    /// Remove embedding for a deleted note.
    func removeNote(id: UUID) {
        var index = loadIndex()
        index.removeValue(forKey: id.uuidString)
        saveIndex(index)
    }

    /// Prune embeddings for note IDs that no longer exist.
    func pruneIndex(keeping noteIDs: Set<UUID>) {
        var index = loadIndex()
        let before = index.count
        index = index.filter { noteIDs.contains(UUID(uuidString: $0.key) ?? UUID()) }
        if index.count != before { saveIndex(index) }
    }

    // MARK: - Similarity search

    /// Find notes most similar to the query text.
    func findSimilar(to query: String, among notes: [Note], apiKey: String, topK: Int = 5) async -> [ContextResult] {
        guard !apiKey.isEmpty, !query.isEmpty else { return [] }
        guard let queryVector = try? await fetchEmbedding(for: query, apiKey: apiKey) else { return [] }
        let index = loadIndex()
        var scored: [(note: Note, score: Double)] = []
        for note in notes {
            guard let record = index[note.id.uuidString] else { continue }
            let sim = cosineSimilarity(queryVector, record.vector)
            if sim > 0.3 { scored.append((note, sim)) }
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { item in
                let snippet = item.note.meetingAttachment?.summary.isEmpty == false
                    ? String(item.note.meetingAttachment!.summary.prefix(120))
                    : String(item.note.body.prefix(120))
                return ContextResult(
                    title: item.note.title.isEmpty ? "Untitled" : item.note.title,
                    snippet: snippet,
                    source: .internalNote(id: item.note.id),
                    score: item.score
                )
            }
    }

    // MARK: - Tag overlap

    func findByTags(_ tags: [String], among notes: [Note], excludingID: UUID) -> [ContextResult] {
        guard !tags.isEmpty else { return [] }
        let tagSet = Set(tags)
        return notes
            .filter { $0.id != excludingID && !Set($0.tags).isDisjoint(with: tagSet) }
            .map { note in
                let overlap = Double(Set(note.tags).intersection(tagSet).count) / Double(tagSet.count)
                let snippet = note.body.prefix(120).isEmpty
                    ? (note.meetingAttachment?.summary.prefix(120) ?? "")
                    : note.body.prefix(120)
                return ContextResult(
                    title: note.title.isEmpty ? "Untitled" : note.title,
                    snippet: String(snippet),
                    source: .internalNote(id: note.id),
                    score: overlap
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Math

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0 * $1.1) }
        let magA = sqrt(a.reduce(0.0) { $0 + Double($1 * $1) })
        let magB = sqrt(b.reduce(0.0) { $0 + Double($1 * $1) })
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }
}

enum EmbeddingError: Error {
    case invalidConfig
    case badResponse
}
