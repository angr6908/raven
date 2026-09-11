import Foundation

nonisolated struct Provider: Identifiable, Codable, Hashable {
    var id = UUID()
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

    var modelsURL: String { v1URL + "/models" }

    var host: String { URL(string: rootURL)?.host() ?? rootURL }
}

nonisolated struct ModelEntry: Identifiable, Codable, Hashable {
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

nonisolated struct ModelsResponse: Codable {
    var data: [ModelEntry]?
    var body: [ModelEntry]?
    var models: [ModelEntry]?

    var entries: [ModelEntry] { data ?? body ?? models ?? [] }
}

nonisolated struct ModelGroup: Identifiable {
    var owner: String
    var models: [ModelEntry]
    var id: String { owner }
}

nonisolated struct ModelWindowOverride: Codable, Hashable {
    var providerID: UUID
    var modelID: String
    var contextWindow: Int
}

nonisolated struct WindowBadge: Hashable {
    var label: String
    var isOverride: Bool
}

nonisolated enum ProviderStatus: Hashable {
    case loading
    case failed
    case empty
    case ready(Int)

    var subtitle: String {
        switch self {
        case .loading: "Loading models…"
        case .failed: "Couldn't connect"
        case .empty: "No models yet"
        case .ready(let count): count == 1 ? "1 model" : "\(count) models"
        }
    }
}

nonisolated enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

nonisolated enum ContextWindow {
    static let fallback = 200_000
    static let presets = [128_000, 200_000, 256_000, 400_000, 1_000_000]

    static func label(_ tokens: Int) -> String {
        let thousand = 1_000, million = 1_000_000
        if tokens >= million, tokens % million == 0 { return "\(tokens / million)M ctx" }
        if tokens >= thousand, tokens % thousand == 0 { return "\(tokens / thousand)K ctx" }
        return "\(tokens) ctx"
    }
}
