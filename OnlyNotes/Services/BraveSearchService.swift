import Foundation

class BraveSearchService {
    private let endpoint = "https://api.search.brave.com/res/v1/web/search"

    func search(query: String, apiKey: String) async throws -> [ContextResult] {
        guard !apiKey.isEmpty, !query.isEmpty else { return [] }
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
