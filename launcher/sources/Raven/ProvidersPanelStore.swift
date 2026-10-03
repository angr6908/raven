import Foundation
import Observation

@MainActor
@Observable
final class ProvidersPanelStore {
    static let shared = ProvidersPanelStore()

    private(set) var providers: [ProviderEntry]?
    private(set) var loading = true
    private(set) var error: String?

    let saver = AutoSaveScheduler()
    private var dirty = false
    private var loadTask: Task<Void, Never>?

    nonisolated static let savedNotice = "Saved — raven reloaded"

    var effortLevels: [String] = PanelLogic.fallbackEffortLevels
    var effortLevelsLoaded = false
    private var effortLevelsTask: Task<Void, Never>?
    var antigravityLevels: [String: [String]] = [:]

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
                let list: [ProviderEntry] = try await PanelClient.shared.get("/api/providers")
                if !self.dirty {
                    self.providers = list
                }
                self.error = nil
            } catch {
                self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            self.loading = false
        }
        loadEffortLevels()
    }

    func loadEffortLevels() {
        guard !effortLevelsLoaded else { return }
        effortLevelsTask?.cancel()
        effortLevelsTask = Task { [weak self] in
            guard let self else { return }
            let levels: [String]
            do {
                let response: EffortLevelsResponse = try await PanelClient.shared.get("/api/effort-levels")
                levels = response.levels.isEmpty ? PanelLogic.fallbackEffortLevels : response.levels
            } catch {
                levels = PanelLogic.fallbackEffortLevels
            }
            guard !Task.isCancelled else { return }
            self.effortLevels = levels
            self.effortLevelsLoaded = true
        }
    }

    private func saveList(_ list: [ProviderEntry]) async throws {
        var copy = list
        for i in copy.indices {
            for j in copy[i].models.indices where copy[i].models[j].alias == "" {
                copy[i].models[j].alias = nil
            }
        }
        try await PanelClient.shared.putVoid("/api/providers", json: copy)
    }

    private func mutate(_ change: (inout [ProviderEntry]) -> Void) {
        guard providers != nil else { return }
        dirty = true
        var list = providers ?? []
        change(&list)
        providers = list
        saver.schedule { [weak self] in
            guard let self else { return }
            try await self.saveList(list)
            self.dirty = false
            self.error = nil
        }
    }

    func updateProvider(index: Int, _ change: @escaping (ProviderEntry) -> ProviderEntry) {
        mutate { list in
            guard index < list.count else { return }
            list[index] = change(list[index])
        }
    }

    func editZone(match: @escaping (ProviderEntry) -> Bool,
                  blank: @escaping () -> ProviderEntry,
                  change: @escaping (ProviderEntry) -> ProviderEntry) {
        mutate { list in
            if let index = list.firstIndex(where: match) {
                list[index] = change(list[index])
            } else {
                list.append(change(blank()))
            }
        }
    }

    func addProvider() {
        mutate { list in
            var entry = PanelLogic.blankProviderEntry(kind: "openai")
            entry.apiKeyEntries = [ApiKeyEntry(apiKey: "")]
            list.insert(entry, at: 0)
        }
    }

    func removeProvider(index: Int) {
        mutate { list in
            guard index < list.count else { return }
            list.remove(at: index)
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

    func fetchZoneModels(kind: String) async throws -> [UpstreamCatalogModel] {
        let response: ZoneModelsResponse = try await PanelClient.shared.get("/api/providers/\(kind)/models")
        return response.models
    }

    func fetchProviderModels(index: Int) async throws -> [UpstreamCatalogModel] {
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
