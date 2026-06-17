import Foundation

class BraveSearchService {
    private let endpoint = "https://api.search.brave.com/res/v1/web/search"

    func search(query: String, apiKey: String) async throws -> [ContextResult] {
        guard !apiKey.isEmpty else { throw BraveSearchError.networkError("Brave API key not set") }
        guard !query.isEmpty else { throw BraveSearchError.networkError("Empty query") }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BraveSearchError.noResponse
            }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown"
                throw BraveSearchError.httpError(http.statusCode, msg)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = json["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]]
            else {
                throw BraveSearchError.parseError
            }

            return results.compactMap { item -> ContextResult? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String
                else { return nil }
                let snippet = item["description"] as? String ?? ""
                return ContextResult(title: title, snippet: snippet, source: .web(url: url), score: 1.0)
            }
        } catch {
            throw BraveSearchError.networkError(error.localizedDescription)
        }
    }

    func answer(query: String, apiKey: String) async throws -> WebAnswer {
        guard !apiKey.isEmpty, !query.isEmpty else { throw BraveSearchError.networkError("No API key or query") }

        guard let url = URL(string: "https://api.search.brave.com/res/v1/chat/completions") else {
            throw BraveSearchError.noResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": "brave-default",
            "messages": [
                ["role": "user", "content": query]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BraveSearchError.noResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw BraveSearchError.httpError(http.statusCode, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BraveSearchError.parseError
        }

        // Parse OpenAI-compatible response
        var answerText = ""
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            answerText = content
        }

        // Parse citations if present
        var citations: [WebAnswerCitation] = []
        if let citationsArr = json["citations"] as? [[String: Any]] {
            for cite in citationsArr {
                if let title = cite["title"] as? String, let url = cite["url"] as? String {
                    citations.append(WebAnswerCitation(title: title, url: url))
                }
            }
        }

        guard !answerText.isEmpty else {
            throw BraveSearchError.parseError
        }

        return WebAnswer(text: answerText, citations: citations)
    }
}

enum BraveSearchError: LocalizedError {
    case noResponse
    case httpError(Int, String)
    case parseError
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noResponse: return "No response from Brave Search"
        case .httpError(let code, let msg): return "Brave Search HTTP \(code): \(msg)"
        case .parseError: return "Could not parse Brave Search response"
        case .networkError(let msg): return "Brave Search error: \(msg)"
        }
    }
}
