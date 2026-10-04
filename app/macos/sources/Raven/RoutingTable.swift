import Foundation

nonisolated struct ChannelSpec: Identifiable, Hashable, Sendable {
    var kind: String
    var title: String
    var symbol: String
    var presetEfforts: Bool

    var id: String { kind }

    static let all: [ChannelSpec] = [
        ChannelSpec(kind: "workbuddy", title: "WorkBuddy", symbol: "cpu", presetEfforts: false),
        ChannelSpec(kind: "antigravity", title: "Antigravity", symbol: "sparkles", presetEfforts: true),
    ]

    static func spec(for kind: String?) -> ChannelSpec? {
        all.first { $0.kind == kind }
    }
}

nonisolated enum RouteStatus: Hashable, Sendable {
    case active
    case hidden
    case incomplete
    case duplicate
    case shadowed(String)

    var rank: Int {
        switch self {
        case .active: 0
        case .hidden: 1
        case .duplicate: 2
        case .shadowed: 3
        case .incomplete: 4
        }
    }

    var title: String {
        switch self {
        case .active: "Active"
        case .hidden: "Hidden"
        case .incomplete: "No model name"
        case .duplicate: "Duplicate"
        case .shadowed(let winner): "Shadowed by \(winner)"
        }
    }

    var label: String {
        switch self {
        case .active: "Active"
        case .hidden: "Hidden"
        case .incomplete: "Unnamed"
        case .duplicate: "Duplicate"
        case .shadowed: "Shadowed"
        }
    }

    var explanation: String {
        switch self {
        case .active: "Clients reach this model by its ID."
        case .hidden: "The provider is off, so /v1/models leaves this out. Requests that name it still route."
        case .incomplete: "Give this row an upstream model name. Until then it routes nothing."
        case .duplicate: "An earlier row in this provider claims the same ID and takes every request."
        case .shadowed(let winner): "\(winner) is listed first and claims the same ID, so it takes every request."
        }
    }

    var isProblem: Bool { rank >= 2 }
}

nonisolated struct RouteRow: Identifiable, Hashable, Sendable {
    var provider: Int
    var model: Int
    var source: String
    var kind: String
    var clientID: String
    var upstream: String
    var context: Int?
    var status: RouteStatus

    var id: String { "\(provider)/\(model)" }
    var contextSort: Int { context ?? 0 }
    var statusRank: Int { status.rank }
}

nonisolated struct RouteMatch: Equatable, Sendable {
    var provider: Int
    var model: Int
    var source: String
    var clientID: String
    var upstream: String
    var effort: String?
    var hidden: Bool
}

nonisolated enum ProviderIssue: Hashable, Sendable {
    case missingName, duplicateName, missingURL, invalidURL, missingKey

    var message: String {
        switch self {
        case .missingName: "Name the provider. Smart aliases and the usage log use it."
        case .duplicateName: "Another provider has this name, so their smart aliases collide."
        case .missingURL: "Add the base URL Raven forwards requests to."
        case .invalidURL: "The base URL needs an http:// or https:// scheme and a host."
        case .missingKey: "No API key. Raven sends requests without authorization."
        }
    }

    var blocking: Bool { self != .missingKey && self != .duplicateName }
}

nonisolated enum RoutingTable {
    static func clientID(_ model: ProviderModelDef) -> String {
        if let alias = model.alias, !alias.isEmpty { return alias }
        return model.name
    }

    static func sourceName(_ entry: ProviderEntry) -> String {
        if let spec = ChannelSpec.spec(for: entry.kind) { return spec.title }
        let name = entry.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    static func find(_ id: String, in providers: [ProviderEntry]) -> (provider: Int, model: Int)? {
        guard !id.isEmpty else { return nil }
        for (index, entry) in providers.enumerated() {
            if let model = entry.models.firstIndex(where: { $0.alias == id || $0.name == id }) {
                return (index, model)
            }
        }
        return nil
    }

    static func splitEffort(_ id: String, levels: [String]) -> (base: String, effort: String)? {
        guard let at = id.lastIndex(of: "@") else { return nil }
        let base = String(id[..<at])
        guard !base.isEmpty else { return nil }
        let suffix = id[id.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard levels.contains(suffix) else { return nil }
        return (base, suffix)
    }

    static func resolve(_ requested: String, in providers: [ProviderEntry], levels: [String]) -> RouteMatch? {
        let raw = requested.trimmingCharacters(in: .whitespaces)
        var alias = raw
        var effort: String?
        if let split = splitEffort(raw, levels: levels), let hit = find(split.base, in: providers) {
            let curated = providers[hit.provider].models[hit.model].thinking?.levels ?? []
            if curated.isEmpty || curated.contains(split.effort) {
                alias = split.base
                effort = split.effort
            }
        }
        guard let hit = find(alias, in: providers) else { return nil }
        let entry = providers[hit.provider]
        let model = entry.models[hit.model]
        return RouteMatch(provider: hit.provider, model: hit.model, source: sourceName(entry),
                          clientID: alias, upstream: model.name.isEmpty ? alias : model.name,
                          effort: effort, hidden: entry.disabled == true)
    }

    static func status(provider: Int, model: Int, in providers: [ProviderEntry]) -> RouteStatus {
        let entry = providers[provider]
        let def = entry.models[model]
        if def.name.trimmingCharacters(in: .whitespaces).isEmpty { return .incomplete }
        if let winner = find(clientID(def), in: providers), winner.provider != provider || winner.model != model {
            return winner.provider == provider ? .duplicate : .shadowed(sourceName(providers[winner.provider]))
        }
        return entry.disabled == true ? .hidden : .active
    }

    static func rows(_ providers: [ProviderEntry]) -> [RouteRow] {
        providers.enumerated().flatMap { index, entry in
            entry.models.enumerated().map { offset, model in
                RouteRow(provider: index, model: offset, source: sourceName(entry), kind: entry.usableKind,
                         clientID: clientID(model), upstream: model.name, context: model.maxContextLength,
                         status: status(provider: index, model: offset, in: providers))
            }
        }
    }

    static func issues(at index: Int, in providers: [ProviderEntry]) -> [ProviderIssue] {
        guard index < providers.count, !providers[index].isManaged else { return [] }
        let entry = providers[index]
        var issues: [ProviderIssue] = []
        let name = entry.name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty {
            issues.append(.missingName)
        } else if providers.enumerated().contains(where: { offset, other in
            offset != index && !other.isManaged && other.name.trimmingCharacters(in: .whitespaces).lowercased() == name
        }) {
            issues.append(.duplicateName)
        }
        let base = (entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
        let reachable = URL(string: base).map {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil
        } ?? false
        if base.isEmpty {
            issues.append(.missingURL)
        } else if !reachable {
            issues.append(.invalidURL)
        }
        if (entry.apiKeyEntries.first?.apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.missingKey)
        }
        return issues
    }

    static func endpoint(_ entry: ProviderEntry) -> String? {
        let base = (entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed + (entry.usableKind == "responses" ? "/responses" : "/chat/completions")
    }

    static func effortSummary(_ levels: [String], order: [String]) -> String {
        guard !levels.isEmpty else { return "All" }
        if levels.count == 1 { return levels[0] }
        let positions = levels.compactMap { order.firstIndex(of: $0) }.sorted()
        if positions.count == levels.count, let first = positions.first, let last = positions.last,
           last - first + 1 == positions.count {
            return "\(order[first])–\(order[last])"
        }
        return levels.joined(separator: ", ")
    }

    static func ordered(_ levels: [String], order: [String]) -> [String] {
        let known = order.filter(levels.contains)
        return known + levels.filter { !order.contains($0) }
    }

    static func reorder<T>(_ items: [T], where isSlot: (T) -> Bool, from source: IndexSet, to destination: Int) -> [T] {
        let slots = items.indices.filter { isSlot(items[$0]) }
        let subset = slots.map { items[$0] }
        let moving = source.sorted().filter { $0 < subset.count }.map { subset[$0] }
        var remaining = subset.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = min(remaining.count, max(0, destination - source.filter { $0 < destination }.count))
        remaining.insert(contentsOf: moving, at: insertAt)
        var result = items
        for (slot, item) in zip(slots, remaining) {
            result[slot] = item
        }
        return result
    }

    static func copyName(_ name: String, existing: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "provider" : name
        let taken = Set(existing.map { $0.lowercased() })
        var candidate = "\(base)-copy"
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)-copy-\(counter)"
            counter += 1
        }
        return candidate
    }
}
