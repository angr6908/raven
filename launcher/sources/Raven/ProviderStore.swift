import Foundation
import Observation

nonisolated struct RavenConfig: Codable {
    var providers: [Provider] = []
    var windowOverrides: [ModelWindowOverride] = []
    var selectedProviderID: UUID?
    var selectedModelID: String?
    var selectedClient: ProviderKind?
    var workdir: String?
}

nonisolated extension RavenConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        windowOverrides = try container.decodeIfPresent([ModelWindowOverride].self, forKey: .windowOverrides) ?? []
        selectedProviderID = try container.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
        selectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        selectedClient = try container.decodeIfPresent(ProviderKind.self, forKey: .selectedClient)
        workdir = try container.decodeIfPresent(String.self, forKey: .workdir)
    }
}

@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    static var configDirectoryOverride: URL?

    static var configDirectory: URL {
        configDirectoryOverride ?? URL.homeDirectory.appending(path: ".raven")
    }

    static var configFile: URL { configDirectory.appending(path: "config.json") }

    static func ensureConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private(set) var providers: [Provider] = []
    private(set) var models: [UUID: [ModelEntry]] = [:]
    private(set) var windowOverrides: [ModelWindowOverride] = []
    private(set) var loading: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]

    var selectedProviderID: UUID? {
        didSet {
            reconcileModelSelection()
            persist()
        }
    }
    var selectedModelID: String? {
        didSet { persist() }
    }
    var selectedClient: ProviderKind = .claude {
        didSet { persist() }
    }
    var workdir: URL = .homeDirectory {
        didSet { persist() }
    }

    var modelSearch = ""
    var providerDraft: ProviderDraft?
    var windowDraft: WindowDraft?
    var pendingRemoval: Provider?
    var launchError: String?
    var isChoosingWorkdir = false

    @ObservationIgnored private var isLoaded = false

    private init() {
        load()
        Task { await refreshAll() }
    }

    private func load() {
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: Self.configFile.path(percentEncoded: false)) else { return }
        do {
            let data = try Data(contentsOf: Self.configFile)
            let config = try JSONDecoder().decode(RavenConfig.self, from: data)
            providers = config.providers
            windowOverrides = config.windowOverrides
            selectedProviderID = config.selectedProviderID ?? providers.first?.id
            selectedModelID = config.selectedModelID
            selectedClient = config.selectedClient ?? .claude
            if let path = config.workdir {
                workdir = URL(filePath: path, directoryHint: .isDirectory)
            }
        } catch {
            NSLog("raven: could not read config: \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard isLoaded else { return }
        do {
            try Self.ensureConfigDirectory()
            let config = RavenConfig(
                providers: providers,
                windowOverrides: windowOverrides,
                selectedProviderID: selectedProviderID,
                selectedModelID: selectedModelID,
                selectedClient: selectedClient,
                workdir: workdir.path(percentEncoded: false)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: Self.configFile, options: .atomic)
        } catch {
            NSLog("raven: could not save config: \(error.localizedDescription)")
        }
    }

    var selectedProvider: Provider? {
        providers.first { $0.id == selectedProviderID }
    }

    var selectedModels: [ModelEntry] {
        selectedProviderID.flatMap { models[$0] } ?? []
    }

    var selectedModelValid: Bool {
        guard let id = selectedModelID else { return false }
        return selectedModels.contains { $0.modelID == id }
    }

    var isRefreshing: Bool { !loading.isEmpty }

    var workdirLabel: String {
        let name = workdir.lastPathComponent
        return name.isEmpty ? "Choose…" : name
    }

    var groupedModels: [ModelGroup] {
        let query = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? selectedModels : selectedModels.filter {
            $0.modelID.lowercased().contains(query)
                || ($0.ownedBy ?? "").lowercased().contains(query)
        }
        return Dictionary(grouping: filtered) { $0.ownedBy ?? "other" }
            .map { ModelGroup(owner: $0.key, models: $0.value.sorted { $0.modelID < $1.modelID }) }
            .sorted { $0.owner < $1.owner }
    }

    func isLoading(_ provider: Provider) -> Bool {
        loading.contains(provider.id)
    }

    func error(for provider: Provider) -> String? {
        errors[provider.id]
    }

    func status(of provider: Provider) -> ProviderStatus {
        if loading.contains(provider.id) { return .loading }
        if errors[provider.id] != nil { return .failed }
        let count = models[provider.id]?.count ?? 0
        return count == 0 ? .empty : .ready(count)
    }

    func beginAddingProvider() {
        providerDraft = ProviderDraft()
    }

    func beginEditing(_ provider: Provider) {
        providerDraft = ProviderDraft(provider)
    }

    func commitProviderDraft() {
        guard let draft = providerDraft, let provider = draft.validated() else { return }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
            if selectedProviderID == nil {
                selectedProviderID = provider.id
            }
        }
        providerDraft = nil
        persist()
        Task { await refresh(provider) }
    }

    func removeProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        models[provider.id] = nil
        errors[provider.id] = nil
        if selectedProviderID == provider.id {
            selectedProviderID = providers.first?.id
        }
        persist()
    }

    var isConfirmingRemoval: Bool {
        get { pendingRemoval != nil }
        set { if !newValue { pendingRemoval = nil } }
    }

    var isShowingLaunchError: Bool {
        get { launchError != nil }
        set { if !newValue { launchError = nil } }
    }

    func windowOverride(providerID: UUID, modelID: String) -> Int? {
        windowOverrides.first {
            $0.providerID == providerID && $0.modelID == modelID
        }?.contextWindow
    }

    func setWindowOverride(providerID: UUID, modelID: String, contextWindow: Int?) {
        windowOverrides.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
        }
        if let contextWindow, contextWindow > 0 {
            windowOverrides.append(
                ModelWindowOverride(providerID: providerID,
                                    modelID: modelID,
                                    contextWindow: contextWindow))
        }
        persist()
    }

    func effectiveWindow(providerID: UUID, modelID: String) -> Int? {
        windowOverride(providerID: providerID, modelID: modelID)
            ?? models[providerID]?.first { $0.modelID == modelID }?.contextWindow
    }

    func windowBadge(for entry: ModelEntry) -> WindowBadge {
        let override = selectedProviderID.flatMap {
            windowOverride(providerID: $0, modelID: entry.modelID)
        }
        if override == nil, entry.contextWindow == nil {
            return WindowBadge(label: "\(ContextWindow.label(ContextWindow.fallback)) default", isOverride: false)
        }
        return WindowBadge(label: ContextWindow.label(override ?? entry.contextWindow ?? ContextWindow.fallback),
                           isOverride: override != nil)
    }

    func beginEditingWindow(for entry: ModelEntry) {
        guard let providerID = selectedProviderID else { return }
        windowDraft = WindowDraft(providerID: providerID,
                                  modelID: entry.modelID,
                                  current: effectiveWindow(providerID: providerID, modelID: entry.modelID))
    }

    func resetWindow(for entry: ModelEntry) {
        guard let providerID = selectedProviderID else { return }
        setWindowOverride(providerID: providerID, modelID: entry.modelID, contextWindow: nil)
    }

    func commitWindowDraft() {
        guard let draft = windowDraft else { return }
        if draft.useAdvertised {
            setWindowOverride(providerID: draft.providerID, modelID: draft.modelID, contextWindow: nil)
        } else if let tokens = draft.tokens {
            setWindowOverride(providerID: draft.providerID, modelID: draft.modelID, contextWindow: tokens)
        }
        windowDraft = nil
    }

    func launch() {
        guard let provider = selectedProvider,
              let model = selectedModelID,
              selectedModelValid else { return }
        Task {
            do {
                try await Launcher.launch(provider: provider, model: model,
                                          client: selectedClient, workdir: workdir)
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    func refreshAll() async {
        await withTaskGroup { group in
            for provider in providers {
                group.addTask { await self.refresh(provider) }
            }
        }
    }

    @discardableResult
    func refresh(_ provider: Provider) async -> Bool {
        loading.insert(provider.id)
        errors[provider.id] = nil
        defer {
            loading.remove(provider.id)
            reconcileModelSelection()
        }
        do {
            models[provider.id] = try await ModelsClient.fetch(provider: provider)
            return true
        } catch {
            models[provider.id] = []
            errors[provider.id] = error.localizedDescription
            return false
        }
    }

    private func reconcileModelSelection() {
        let models = selectedModels
        guard !models.isEmpty else { return }
        if !models.contains(where: { $0.modelID == selectedModelID }) {
            selectedModelID = models.first?.modelID
        }
    }
}
