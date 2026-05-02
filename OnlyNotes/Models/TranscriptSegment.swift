import Foundation

struct TranscriptSegment: Identifiable, Codable, Hashable {
    let id: UUID
    var speakerTag: Int        // raw tag from Google (1, 2, 3...)
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval

    init(id: UUID = UUID(), speakerTag: Int, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.speakerTag = speakerTag
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
