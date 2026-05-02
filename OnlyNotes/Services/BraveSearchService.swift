import Foundation

class BraveSearchService {
    private let endpoint = "https://api.search.brave.com/res/v1/web/search"

    func search(query: String, apiKey: String) async -> [ContextResult] {
        guard !apiKey.isEmpty, !query.isEmpty else { return [] }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { item -> ContextResult? in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String
            else { return nil }
            let snippet = item["description"] as? String ?? ""
            return ContextResult(title: title, snippet: snippet, source: .web(url: url), score: 1.0)
        }
    }
}
