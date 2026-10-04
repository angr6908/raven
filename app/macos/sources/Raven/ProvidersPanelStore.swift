import Foundation
import Observation

nonisolated enum RouteSource: Hashable, Sendable, Identifiable {
    case channel(String)
    case provider(UUID)

    var id: Self { self }
}

@MainActor
@Observable
final class ProvidersPanelStore {
    static let shared = ProvidersPanelStore()

    private(set) var providers: [ProviderEntry]?
    private(set) var ids: [UUID] = []
    private(set) var loading = true
    private(set) var error: String?
    private(set) var effortLevels: [String] = PanelLogic.fallbackEffortLevels
    private(set) var antigravityLevels: [String: [String]] = [:]

    let saver = AutoSaveScheduler()
    private var revision = 0
    private var savedRevision = 0
    private var loadTask: Task<Void, Never>?
    private var effortLevelsLoaded = false
    private var effortLevelsTask: Task<Void, Never>?
    private var antigravityTask: Task<Void, Never>?

    var list: [ProviderEntry] { providers ?? [] }

    private var dirty: Bool { revision != savedRevision }

    func start() {
        guard providers == nil || loading else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        loading = providers == nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: [ProviderEntry] = try await PanelClient.shared.get("/api/providers")
                guard !Task.isCancelled else { return }
                if !self.dirty {
                    let aliased = fetched.map(PanelLogic.withAliases)
                    self.ids = Self.carry(ids: self.ids, from: self.list, to: aliased)
                    self.providers = aliased
                    if aliased != fetched {
                        self.revision += 1
                        self.scheduleSave()
                    }
                }
                self.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            self.loading = false
        }
        loadEffortLevels()
    }

    private func loadEffortLevels() {
        guard !effortLevelsLoaded else { return }
        effortLevelsTask?.cancel()
        effortLevelsTask = Task { [weak self] in
            let levels: [String]
            do {
                let response: EffortLevelsResponse = try await PanelClient.shared.get("/api/effort-levels")
                levels = response.levels.isEmpty ? PanelLogic.fallbackEffortLevels : response.levels
            } catch {
                levels = PanelLogic.fallbackEffortLevels
            }
            guard !Task.isCancelled, let self else { return }
            self.effortLevels = levels
            self.effortLevelsLoaded = true
        }
    }

    func loadAntigravityLevels() {
        guard antigravityLevels.isEmpty, antigravityTask == nil else { return }
        antigravityTask = Task { [weak self] in
            let models = try? await self?.fetchZoneModels(kind: "antigravity")
            guard let self else { return }
            if let models { self.updateAntigravityLevels(from: models) }
            self.antigravityTask = nil
        }
    }

    private static func carry(ids: [UUID], from old: [ProviderEntry], to new: [ProviderEntry]) -> [UUID] {
        var unused = Array(zip(old, ids))
        return new.map { entry in
            if let match = unused.firstIndex(where: { $0.0.name == entry.name && $0.0.kind == entry.kind }) {
                return unused.remove(at: match).1
            }
            return UUID()
        }
    }

    func index(of source: RouteSource) -> Int? {
        switch source {
        case .channel(let kind): list.firstIndex { $0.kind == kind }
        case .provider(let id): ids.firstIndex(of: id)
        }
    }

    func entry(_ source: RouteSource) -> ProviderEntry? {
        index(of: source).map { list[$0] }
    }

    var upstreams: [(id: UUID, index: Int, entry: ProviderEntry)] {
        zip(list.indices, zip(ids, list)).compactMap { index, pair in
            pair.1.isManaged ? nil : (pair.0, index, pair.1)
        }
    }

    private func mutate(_ change: (inout [ProviderEntry], inout [UUID]) -> Void) {
        guard var next = providers else { return }
        var keys = ids
        change(&next, &keys)
        providers = next.map(PanelLogic.withAliases)
        ids = keys
        revision += 1
        scheduleSave()
    }

    func scheduleSave() {
        guard let snapshot = providers else { return }
        let stamp = revision
        saver.schedule { [weak self] in
            try await Self.save(snapshot)
            guard let self else { return }
            self.savedRevision = max(self.savedRevision, stamp)
            await ProviderStore.shared.refresh(LocalProxy.provider)
        }
    }

    private static func save(_ list: [ProviderEntry]) async throws {
        try await PanelClient.shared.putVoid("/api/providers", json: list)
    }

    func edit(_ source: RouteSource, _ change: @escaping (inout ProviderEntry) -> Void) {
        mutate { list, keys in
            switch source {
            case .channel(let kind):
                if let index = list.firstIndex(where: { $0.kind == kind }) {
                    change(&list[index])
                } else {
                    var blank = PanelLogic.blankProviderEntry(kind: kind, name: kind)
                    change(&blank)
                    list.append(blank)
                    keys.append(UUID())
                }
            case .provider(let id):
                guard let index = keys.firstIndex(of: id), index < list.count else { return }
                change(&list[index])
            }
        }
    }

    func setEnabled(_ source: RouteSource, _ on: Bool) {
        edit(source) { $0.disabled = !on }
    }

    @discardableResult
    func addProvider() -> UUID {
        let id = UUID()
        mutate { list, keys in
            var entry = PanelLogic.blankProviderEntry(kind: "openai")
            entry.apiKeyEntries = [ApiKeyEntry(apiKey: "")]
            list.append(entry)
            keys.append(id)
        }
        return id
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let index = ids.firstIndex(of: id), index < list.count else { return nil }
        let copyID = UUID()
        let names = list.map(\.name)
        mutate { list, keys in
            let old = list[index]
            var copy = old
            copy.name = RoutingTable.copyName(old.name, existing: names)
            list.insert(copy, at: index + 1)
            keys.insert(copyID, at: index + 1)
        }
        return copyID
    }

    func remove(_ id: UUID) {
        mutate { list, keys in
            guard let index = keys.firstIndex(of: id), index < list.count else { return }
            list.remove(at: index)
            keys.remove(at: index)
        }
    }

    func moveUpstreams(from source: IndexSet, to destination: Int) {
        mutate { list, keys in
            let pairs = RoutingTable.reorder(Array(zip(list, keys)), where: { !$0.0.isManaged },
                                             from: source, to: destination)
            list = pairs.map(\.0)
            keys = pairs.map(\.1)
        }
    }

    func moveUpstream(_ id: UUID, by offset: Int) {
        guard let position = upstreams.firstIndex(where: { $0.id == id }) else { return }
        let target = position + offset
        guard target >= 0, target < upstreams.count else { return }
        moveUpstreams(from: [position], to: offset > 0 ? target + 1 : target)
    }

    func updateModel(_ source: RouteSource, at index: Int, _ change: @escaping (inout ProviderModelDef) -> Void) {
        edit(source) { entry in
            guard index < entry.models.count else { return }
            change(&entry.models[index])
        }
    }

    func addBlankModel(_ source: RouteSource) {
        edit(source) { $0.models.append(ProviderModelDef(name: "")) }
    }

    func addModels(_ source: RouteSource, _ upstream: [UpstreamCatalogModel]) {
        edit(source) { entry in
            var existing = Set(entry.models.map { $0.name.lowercased() })
            for model in upstream where !existing.contains(model.id.lowercased()) {
                existing.insert(model.id.lowercased())
                var def = ProviderModelDef(name: model.id)
                if let context = model.contextLength, context > 0 { def.maxContextLength = context }
                entry.models.append(def)
            }
        }
    }

    func removeModels(_ source: RouteSource, at offsets: IndexSet) {
        edit(source) { entry in
            for index in offsets.sorted(by: >) where index < entry.models.count {
                entry.models.remove(at: index)
            }
        }
    }

    func updateAntigravityLevels(from models: [UpstreamCatalogModel]) {
        var levels: [String: [String]] = [:]
        levels.reserveCapacity(models.count)
        for model in models {
            levels[model.id] = model.thinking?.levels ?? []
        }
        antigravityLevels = levels
    }

    func catalog(for source: RouteSource) async throws -> [UpstreamCatalogModel] {
        switch source {
        case .channel(let kind):
            let models = try await fetchZoneModels(kind: kind)
            if kind == "antigravity" { updateAntigravityLevels(from: models) }
            return models
        case .provider(let id):
            guard await saver.flush() else {
                if case .failed(let message) = saver.status {
                    throw PanelError.api(code: nil, message: "Unsaved changes: \(message)")
                }
                throw PanelError.api(code: nil, message: "Unsaved changes couldn't be saved.")
            }
            guard let index = ids.firstIndex(of: id) else {
                throw PanelError.api(code: nil, message: "This provider no longer exists.")
            }
            return try await fetchProviderModels(index: index)
        }
    }

    private func fetchZoneModels(kind: String) async throws -> [UpstreamCatalogModel] {
        let response: ZoneModelsResponse = try await PanelClient.shared.get("/api/providers/\(kind)/models")
        return response.models
    }

    private func fetchProviderModels(index: Int) async throws -> [UpstreamCatalogModel] {
        let response: ProviderProbeResponse = try await PanelClient.shared.get(
            "/api/providers/models", query: [URLQueryItem(name: "index", value: String(index))])
        if let entries = response.entries, !entries.isEmpty { return entries }
        return response.models.map { UpstreamCatalogModel(id: $0) }
    }

    func fetchModelsDev(model: String) async throws -> ModelsDevLookup {
        let name = PanelAggregation.stripModelVendorAndProvider(model)
        return try await PanelClient.shared.get("/api/models-dev",
                                                query: [URLQueryItem(name: "model", value: name)])
    }
}
