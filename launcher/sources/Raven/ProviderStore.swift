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
    var recents: [RecentLaunch] = []
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
        recents = try container.decodeIfPresent([RecentLaunch].self, forKey: .recents) ?? []
    }
}

@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    static var configDirectoryOverride: URL?

    static var configDirectory: URL {
        if let override = configDirectoryOverride { return override }
        if let path = ProcessInfo.processInfo.environment["RAVEN_DATA_DIR"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.homeDirectory
            .appending(path: "Documents")
            .appending(path: "raven")
            .appending(path: "data", directoryHint: .isDirectory)
    }

    static var configFile: URL { configDirectory.appending(path: "config.json") }

    static let recentsLimit = 12

    static func ensureConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private(set) var providers: [Provider] = []
    private(set) var models: [UUID: [ModelEntry]] = [:]
    private(set) var windowOverrides: [ModelWindowOverride] = []
    private(set) var pinned: [ModelRef] = []
    private(set) var recents: [RecentLaunch] = []
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
        didSet { persist() }
    }

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
            pinned = config.pinned
            recents = config.recents
            client = config.selectedClient ?? .claude
            if let providerID = config.selectedProviderID, let modelID = config.selectedModelID {
                selection = ModelRef(providerID: providerID, modelID: modelID)
            }
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
                selectedProviderID: selection?.providerID,
                selectedModelID: selection?.modelID,
                selectedClient: client,
                workdir: workdir.path(percentEncoded: false),
                pinned: pinned,
                recents: recents
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: Self.configFile, options: .atomic)
        } catch {
            NSLog("raven: could not save config: \(error.localizedDescription)")
        }
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

    var recentWorkdirs: [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for recent in recents where !seen.contains(recent.workdir) {
            seen.insert(recent.workdir)
            result.append(URL(filePath: recent.workdir, directoryHint: .isDirectory))
        }
        return Array(result.prefix(6))
    }

    func isLoading(_ provider: Provider) -> Bool {
        loading.contains(provider.id)
    }

    func error(for provider: Provider) -> String? {
        errors[provider.id]
    }

    func refreshedAt(_ provider: Provider) -> Date? {
        refreshedAt[provider.id]
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
        recents.removeAll { $0.providerID == provider.id }
        windowOverrides.removeAll { $0.providerID == provider.id }
        if selection?.providerID == provider.id {
            selection = nil
        }
        persist()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
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

    func apply(_ draft: WindowDraft) {
        if draft.useAdvertised {
            setWindowOverride(providerID: draft.providerID, modelID: draft.modelID, contextWindow: nil)
        } else if let tokens = draft.tokens {
            setWindowOverride(providerID: draft.providerID, modelID: draft.modelID, contextWindow: tokens)
        }
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

    func recordLaunch(_ item: ModelItem) {
        let path = workdirPath
        recents.removeAll {
            $0.ref == item.ref && $0.client == client && $0.workdir == path
        }
        recents.insert(RecentLaunch(providerID: item.provider.id, modelID: item.entry.modelID,
                                    client: client, workdir: path, date: .now), at: 0)
        if recents.count > Self.recentsLimit {
            recents.removeLast(recents.count - Self.recentsLimit)
        }
        persist()
    }

    func clearRecents() {
        recents.removeAll()
        persist()
    }

    func restore(_ recent: RecentLaunch) {
        guard providers.contains(where: { $0.id == recent.providerID }) else { return }
        client = recent.client
        workdir = URL(filePath: recent.workdir, directoryHint: .isDirectory)
        selection = recent.ref
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
        recordLaunch(item)
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
