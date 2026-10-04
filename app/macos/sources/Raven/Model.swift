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
        case contextLength = "context_length"
        case contextWindowAlias = "context_window"
    }

    init(modelID: String, ownedBy: String?, contextWindow: Int?) {
        self.modelID = modelID
        self.ownedBy = ownedBy
        self.contextWindow = contextWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
            ?? container.decodeIfPresent(Int.self, forKey: .contextWindowAlias)
            ?? container.decodeIfPresent(Int.self, forKey: .contextLength)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(ownedBy, forKey: .ownedBy)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
    }

    var owner: String { ownedBy ?? "Other" }


    var family: ModelFamily { ModelFamily(modelID: modelID) }
}

nonisolated struct ModelRef: Identifiable, Codable, Hashable {
    var providerID: UUID
    var modelID: String

    var id: String { providerID.uuidString + "/" + modelID }
}

nonisolated struct ModelItem: Identifiable, Hashable {
    var provider: Provider
    var entry: ModelEntry

    var ref: ModelRef { ModelRef(providerID: provider.id, modelID: entry.modelID) }
    var id: String { ref.id }
}

nonisolated enum SectionKind: Hashable {
    case provider(Provider)
    case owner(String)

    var title: String {
        switch self {
        case .provider(let provider): provider.name
        case .owner(let owner): owner
        }
    }
}

nonisolated struct ModelSection: Identifiable {
    var kind: SectionKind
    var items: [ModelItem]

    var id: String {
        switch kind {
        case .provider(let provider): "provider/" + provider.id.uuidString
        case .owner(let owner): "owner/" + owner
        }
    }
}

nonisolated enum ModelFamily: Hashable {
    case claude, gpt, gemini, deepseek, llama, mistral, qwen, grok, kimi, minimax, glm, mimo, other

    init(modelID: String) {
        var id = modelID.lowercased()
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        if let at = id.firstIndex(of: "@") {
            id = String(id[..<at])
        }
        id = id.trimmingCharacters(in: CharacterSet(charactersIn: "~-_ ."))
        let table: [(String, ModelFamily)] = [
            ("claude", .claude), ("gpt", .gpt), ("o1", .gpt), ("o3", .gpt), ("o4", .gpt),
            ("gemini", .gemini), ("deepseek", .deepseek), ("llama", .llama),
            ("mistral", .mistral), ("mixtral", .mistral), ("codestral", .mistral),
            ("qwen", .qwen), ("grok", .grok), ("kimi", .kimi), ("minimax", .minimax), ("glm", .glm), ("mimo", .mimo),
        ]
        self = table.first { id.hasPrefix($0.0) }?.1 ?? .other
    }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .gpt: "GPT"
        case .gemini: "Gemini"
        case .deepseek: "DeepSeek"
        case .llama: "Llama"
        case .mistral: "Mistral"
        case .qwen: "Qwen"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .minimax: "MiniMax"
        case .glm: "GLM"
        case .mimo: "MiMo"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .gpt: "circle.hexagongrid"
        case .gemini: "diamond"
        case .deepseek: "drop"
        case .llama: "hare"
        case .mistral: "wind"
        case .qwen: "cloud"
        case .grok: "bolt"
        case .kimi: "moon.stars"
        case .minimax: "waveform"
        case .glm: "hexagon"
        case .mimo: "m.square"
        case .other: "cube"
        }
    }
}

nonisolated struct ModelsResponse: Codable {
    var data: [ModelEntry]?
    var body: [ModelEntry]?
    var models: [ModelEntry]?

    var entries: [ModelEntry] { data ?? body ?? models ?? [] }
}

nonisolated struct ModelWindowOverride: Codable, Hashable {
    var providerID: UUID
    var modelID: String
    var contextWindow: Int
}

nonisolated struct RecentLaunch: Identifiable, Codable, Hashable {
    var id = UUID()
    var providerID: UUID
    var modelID: String
    var client: ProviderKind
    var workdir: String
    var date: Date

    var ref: ModelRef { ModelRef(providerID: providerID, modelID: modelID) }

    var folderName: String {
        let name = URL(filePath: workdir, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? workdir : name
    }
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

    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

nonisolated enum ContextWindow {
    static let fallback = 200_000
    static let presets = [128_000, 200_000, 256_000, 400_000, 1_000_000]

    static func label(_ tokens: Int) -> String {
        let thousand = 1_000, million = 1_000_000
        if tokens >= million {
            if tokens % million == 0 { return "\(tokens / million)M ctx" }
            var text = String(format: "%.2f", Double(tokens) / Double(million))
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return "\(text)M ctx"
        }
        if tokens >= thousand, tokens % thousand == 0 { return "\(tokens / thousand)K ctx" }
        return "\(tokens) ctx"
    }

    static func compact(_ tokens: Int) -> String {
        let thousand = 1_000, million = 1_000_000
        if tokens >= million, tokens % million == 0 { return "\(tokens / million)M" }
        if tokens >= thousand, tokens % thousand == 0 { return "\(tokens / thousand)K" }
        return tokens.formatted(.number.grouping(.automatic))
    }
}

nonisolated enum LocalProxy {
    static let name = "Raven"
    static let port: UInt16 = 3458
    static let baseURL = "http://127.0.0.1:\(port)"
}
