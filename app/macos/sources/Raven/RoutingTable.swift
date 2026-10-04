import Foundation

nonisolated struct ChannelSpec: Identifiable, Hashable, Sendable {
    var kind: String
    var title: String

    var id: String { kind }

    static let all: [ChannelSpec] = [
        ChannelSpec(kind: "workbuddy", title: "WorkBuddy"),
        ChannelSpec(kind: "antigravity", title: "Antigravity"),
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

nonisolated struct RouteRow: Hashable, Sendable {
    var kind: String
    var status: RouteStatus
}

nonisolated enum ProviderIssue: Hashable, Sendable {
    case missingName, duplicateName, missingURL, invalidURL, missingKey

    var message: String {
        switch self {
        case .missingName, .missingURL: "Required"
        case .duplicateName: "Already used by another provider"
        case .invalidURL: "Needs http:// or https://"
        case .missingKey: "Not set"
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
            entry.models.indices.map { offset in
                RouteRow(kind: entry.usableKind, status: status(provider: index, model: offset, in: providers))
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
