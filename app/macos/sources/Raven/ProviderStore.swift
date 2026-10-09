import Foundation
import Observation

nonisolated struct RavenConfig: Codable {
    var providers: [Provider] = []
    var windowOverrides: [ModelWindowOverride] = []
    var selectedProviderID: UUID?
    var selectedModelID: String?
    var selectedClient: ProviderKind?
    var workdir: String?
    var pinned: [ModelRef] = []
    var recentWorkdirs: [String] = []
    var transient: TransientSettings?
}

nonisolated struct TransientSettings: Codable, Equatable {
    var client: ProviderKind?
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
        pinned = try container.decodeIfPresent([ModelRef].self, forKey: .pinned) ?? []
        recentWorkdirs = try container.decodeIfPresent([String].self, forKey: .recentWorkdirs) ?? []
        transient = try container.decodeIfPresent(TransientSettings.self, forKey: .transient)
    }
}

@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    nonisolated(unsafe) static var configDirectoryOverride: URL?

    nonisolated static var configDirectory: URL {
        if let override = configDirectoryOverride { return override }
        if let path = ProcessInfo.processInfo.environment["RAVEN_DATA_DIR"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.homeDirectory
            .appending(path: "Documents")
            .appending(path: "raven")
            .appending(path: "data", directoryHint: .isDirectory)
    }

    nonisolated static var configFile: URL { configDirectory.appending(path: "config.json") }

    static let recentsLimit = 12

    nonisolated static func ensureConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private(set) var providers: [Provider] = [LocalProxy.provider]
    private(set) var models: [UUID: [ModelEntry]] = [:]
    private(set) var windowOverrides: [ModelWindowOverride] = []
    private(set) var pinned: [ModelRef] = []
    private(set) var recentWorkdirPaths: [String] = []
    private(set) var loading: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshedAt: [UUID: Date] = [:]

    var selection: ModelRef? {
        didSet { persist() }
    }

    var client: ProviderKind = .claude {
        didSet { persist() }
    }

    var workdir: URL = .homeDirectory {
        didSet {
            guard workdir != oldValue else { return }
            rememberWorkdir()
            persist()
        }
    }

    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

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
            providers = [LocalProxy.provider] + config.providers.filter { !$0.isBuiltIn }
            windowOverrides = config.windowOverrides
            pinned = config.pinned
            recentWorkdirPaths = config.recentWorkdirs
            client = config.selectedClient ?? .claude
            if let providerID = config.selectedProviderID, let modelID = config.selectedModelID {
                selection = ModelRef(providerID: providerID, modelID: modelID)
            }
            if let path = config.workdir {
                workdir = URL(filePath: path, directoryHint: .isDirectory)
            }
            if let transient = config.transient {
                if let saved = transient.client { client = saved }
                if let path = transient.workdir {
                    workdir = URL(filePath: path, directoryHint: .isDirectory)
                }
            }
        } catch {
            NSLog("raven: could not read config: \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard isLoaded else { return }
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.saveInBackground()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        Self.write(snapshot())
    }

    private func saveInBackground() async {
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        let config = snapshot()
        await Task.detached(priority: .utility) { Self.write(config) }.value
    }

    private func snapshot() -> RavenConfig {
        RavenConfig(
            providers: customProviders,
            windowOverrides: windowOverrides,
            selectedProviderID: selection?.providerID,
            selectedModelID: selection?.modelID,
            selectedClient: client,
            workdir: workdir.path(percentEncoded: false),
            pinned: pinned,
            recentWorkdirs: recentWorkdirPaths,
            transient: TransientSettings(client: client, workdir: workdirPath)
        )
    }

    private nonisolated static func write(_ config: RavenConfig) {
        do {
            try ensureConfigDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configFile, options: .atomic)
        } catch {
            NSLog("raven: could not save config: \(error.localizedDescription)")
        }
    }

    var customProviders: [Provider] {
        providers.filter { !$0.isBuiltIn }
    }

    func provider(id: UUID) -> Provider? {
        providers.first { $0.id == id }
    }

    func entries(of provider: Provider) -> [ModelEntry] {
        (models[provider.id] ?? []).sorted {
            $0.modelID.localizedStandardCompare($1.modelID) == .orderedAscending
        }
    }

    func items(of provider: Provider) -> [ModelItem] {
        entries(of: provider).map { ModelItem(provider: provider, entry: $0) }
    }

    func item(_ ref: ModelRef) -> ModelItem? {
        guard let provider = provider(id: ref.providerID),
              let entry = models[ref.providerID]?.first(where: { $0.modelID == ref.modelID })
        else { return nil }
        return ModelItem(provider: provider, entry: entry)
    }

    var libraryItems: [ModelItem] {
        providers.flatMap { items(of: $0) }
    }

    var pinnedItems: [ModelItem] {
        pinned.compactMap { item($0) }
    }

    var modelCount: Int {
        models.values.reduce(0) { $0 + $1.count }
    }

    var selectedItem: ModelItem? {
        selection.flatMap { item($0) }
    }

    var canLaunch: Bool { selectedItem != nil }

    var isRefreshing: Bool { !loading.isEmpty }

    var workdirPath: String { workdir.path(percentEncoded: false) }

    var workdirLabel: String {
        let name = workdir.lastPathComponent
        return name.isEmpty ? "Choose…" : name
    }

    func rememberWorkdir() {
        let path = workdirPath
        guard !recentWorkdirPaths.contains(path) else { return }
        recentWorkdirPaths.insert(path, at: 0)
        if recentWorkdirPaths.count > Self.recentsLimit {
            recentWorkdirPaths.removeLast(recentWorkdirPaths.count - Self.recentsLimit)
        }
        persist()
    }

    var recentWorkdirs: [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for path in recentWorkdirPaths where !seen.contains(path) {
            seen.insert(path)
            result.append(URL(filePath: path, directoryHint: .isDirectory))
        }
        return Array(result.prefix(6))
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

    @discardableResult
    func apply(_ draft: ProviderDraft) -> Provider? {
        guard let provider = draft.validated() else { return nil }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        persist()
        Task { await refresh(provider) }
        return provider
    }

    func removeProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        models[provider.id] = nil
        errors[provider.id] = nil
        refreshedAt[provider.id] = nil
        pinned.removeAll { $0.providerID == provider.id }
        windowOverrides.removeAll { $0.providerID == provider.id }
        if selection?.providerID == provider.id {
            selection = nil
        }
        persist()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        var custom = customProviders
        var moved: [Provider] = []
        for index in source {
            moved.append(custom[index])
        }
        for index in source.reversed() {
            custom.remove(at: index)
        }
        let offset = destination - source.filter { $0 < destination }.count
        custom.insert(contentsOf: moved, at: min(max(offset, 0), custom.count))
        providers = [LocalProxy.provider] + custom
        persist()
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

    func setWindowOverride(_ ref: ModelRef, tokens: Int?) {
        setWindowOverride(providerID: ref.providerID, modelID: ref.modelID, contextWindow: tokens)
    }

    func clearWindowOverrides() {
        windowOverrides.removeAll()
        persist()
    }

    func effectiveWindow(providerID: UUID, modelID: String) -> Int? {
        windowOverride(providerID: providerID, modelID: modelID)
            ?? models[providerID]?.first { $0.modelID == modelID }?.contextWindow
    }

    func effectiveWindow(_ item: ModelItem) -> Int {
        effectiveWindow(providerID: item.provider.id, modelID: item.entry.modelID) ?? ContextWindow.fallback
    }

    func windowBadge(for item: ModelItem) -> WindowBadge {
        let override = windowOverride(providerID: item.provider.id, modelID: item.entry.modelID)
        return WindowBadge(label: ContextWindow.label(override ?? item.entry.contextWindow ?? ContextWindow.fallback),
                           isOverride: override != nil)
    }

    func isPinned(_ item: ModelItem) -> Bool {
        pinned.contains(item.ref)
    }

    func togglePin(_ item: ModelItem) {
        if let index = pinned.firstIndex(of: item.ref) {
            pinned.remove(at: index)
        } else {
            pinned.append(item.ref)
        }
        persist()
    }

    func launchScript() -> String? {
        guard let item = selectedItem else { return nil }
        return Launcher.makeScript(provider: item.provider, model: item.entry.modelID,
                                   client: client, workdir: workdir)
    }

    func launch() async throws {
        guard let item = selectedItem else { return }
        try await Launcher.launch(provider: item.provider, model: item.entry.modelID,
                                  client: client, workdir: workdir)
    }

    func refreshAll() async {
        let refreshes = providers.map { provider in
            Task { await self.refresh(provider) }
        }
        for refresh in refreshes {
            _ = await refresh.value
        }
    }

    @discardableResult
    func refresh(_ provider: Provider) async -> Bool {
        loading.insert(provider.id)
        errors[provider.id] = nil
        defer {
            loading.remove(provider.id)
            reconcileSelection()
        }
        do {
            models[provider.id] = try await ModelsClient.fetch(provider: provider)
            refreshedAt[provider.id] = .now
            return true
        } catch {
            models[provider.id] = []
            errors[provider.id] = error.localizedDescription
            return false
        }
    }

    private func reconcileSelection() {
        guard let ref = selection else { return }
        guard let provider = provider(id: ref.providerID) else {
            selection = nil
            return
        }
        let entries = models[provider.id] ?? []
        guard !entries.isEmpty else { return }
        if !entries.contains(where: { $0.modelID == ref.modelID }) {
            selection = nil
        }
    }
}
