import Foundation

enum ContextSource {
    case internalNote(id: UUID)
    case web(url: String)
}

struct ContextResult: Identifiable {
    var id: String {
        switch source {
        case .internalNote(let uuid): return "note-\(uuid)"
        case .web(let url): return "web-\(url)"
        }
    }
    let title: String
    let snippet: String
    let source: ContextSource
    let score: Double  // 0–1, higher is more relevant
}
