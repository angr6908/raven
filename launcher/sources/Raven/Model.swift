import Foundation
import SwiftUI

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

    var accent: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red]
        let seed = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[seed % palette.count]
    }
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

    var owner: String { ownedBy ?? "Other" }

    var shortName: String {
        modelID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? modelID
    }

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

nonisolated enum Destination: Hashable {
    case library
    case pinned
    case recents
    case provider(UUID)

    var symbol: String {
        switch self {
        case .library: "square.stack.3d.up"
        case .pinned: "pin.fill"
        case .recents: "clock.arrow.circlepath"
        case .provider: "server.rack"
        }
    }
}

nonisolated enum ModelFamily: Hashable {
    case claude, gpt, gemini, deepseek, llama, mistral, qwen, grok, kimi, minimax, glm, other

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
            ("qwen", .qwen), ("grok", .grok), ("kimi", .kimi), ("minimax", .minimax), ("glm", .glm),
        ]
        self = table.first { id.hasPrefix($0.0) }?.1 ?? .other
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
        case .other: "cube"
        }
    }

    var tint: Color {
        switch self {
        case .claude: .orange
        case .gpt: .green
        case .gemini: .blue
        case .deepseek: .indigo
        case .llama: .purple
        case .mistral: .red
        case .qwen: .cyan
        case .grok: .gray
        case .kimi: .teal
        case .minimax: .pink
        case .glm: .mint
        case .other: .secondary
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

    var tint: Color {
        switch self {
        case .failed: .red
        case .ready: .green
        case .loading, .empty: .secondary
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
        if tokens >= million, tokens % million == 0 { return "\(tokens / million)M ctx" }
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
    static let baseURL = "http://127.0.0.1:3458"
}
