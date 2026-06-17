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

struct WebAnswerCitation {
    let title: String
    let url: String
}

struct WebAnswer {
    let text: String
    let citations: [WebAnswerCitation]
}

enum WebContextState {
    case idle           // no query yet
    case disabled       // no Brave key set
    case loading        // request in flight
    case failed(String) // error message
    case noResults      // request succeeded, no results
    case answer(WebAnswer) // success with answer
}
