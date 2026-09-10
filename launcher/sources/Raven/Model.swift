import Foundation

struct Provider: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var apiKey: String

    var rootURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    var v1URL: String {
        let root = rootURL
        return root.hasSuffix("/v1") ? root : root + "/v1"
    }
}

struct ModelEntry: Identifiable, Codable, Equatable, Hashable {
    var id: String { modelID }
    var modelID: String
    var ownedBy: String?
    var contextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case ownedBy = "owned_by"
        case contextWindow = "max_context_length"
    }
}

struct ModelsResponse: Codable {
    var data: [ModelEntry]?
    var bodyData: [ModelEntry]?
    var models: [ModelEntry]?

    var entries: [ModelEntry] {
        data ?? bodyData ?? models ?? []
    }

    enum CodingKeys: String, CodingKey {
        case data, models
        case bodyData = "body"
    }
}

struct ModelWindowOverride: Codable, Equatable, Hashable {
    var providerID: UUID
    var modelID: String
    var contextWindow: Int
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
