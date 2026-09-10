import Foundation

enum ModelsClientError: LocalizedError {
    case badURL
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL: return "The base URL is not valid"
        case .http(let code): return "HTTP \(code)"
        case .empty: return "No models returned"
        }
    }
}

enum ModelsClient {
    static func fetch(provider: Provider) async throws -> [ModelEntry] {
        var candidates = [provider.v1URL + "/models"]
        let bare = provider.rootURL + "/models"
        if bare != candidates[0] { candidates.append(bare) }

        var lastError: Error = ModelsClientError.badURL
        for url in candidates {
            do {
                return try await fetchModels(at: url, apiKey: provider.apiKey)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchModels(at urlString: String, apiKey: String) async throws -> [ModelEntry] {
        guard let url = URL(string: urlString) else { throw ModelsClientError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelsClientError.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let entries = decoded.entries
        guard !entries.isEmpty else { throw ModelsClientError.empty }
        return entries
    }
}
