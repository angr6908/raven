import Foundation
import Combine

struct RavenConfig: Codable {
    var providers: [Provider]
    var windowOverrides: [ModelWindowOverride]
    var selectedProviderID: UUID?
    var selectedModelID: String?
    var selectedClient: String?

    init(providers: [Provider],
         windowOverrides: [ModelWindowOverride],
         selectedProviderID: UUID?,
         selectedModelID: String?,
         selectedClient: String?) {
        self.providers = providers
        self.windowOverrides = windowOverrides
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.selectedClient = selectedClient
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        windowOverrides = try c.decodeIfPresent([ModelWindowOverride].self, forKey: .windowOverrides) ?? []
        selectedProviderID = try c.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
        selectedModelID = try c.decodeIfPresent(String.self, forKey: .selectedModelID)
        selectedClient = try c.decodeIfPresent(String.self, forKey: .selectedClient)
    }
}

@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    nonisolated static var configDirectory: URL {
        if let override = configDirectoryOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".raven")
    }
    nonisolated static var configDirectoryOverride: URL? {
        get { _configDirectoryOverride }
        set { _configDirectoryOverride = newValue }
    }
    nonisolated(unsafe) private static var _configDirectoryOverride: URL?
    nonisolated static var configFile: URL { configDirectory.appendingPathComponent("config.json") }

    nonisolated static func ensureConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    @Published private(set) var providers: [Provider] = []
    @Published private(set) var models: [UUID: [ModelEntry]] = [:]
    @Published private(set) var windowOverrides: [ModelWindowOverride] = []
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var selectedProviderID: UUID?
    @Published var selectedModelID: String?
    @Published var selectedClient: ProviderKind = .claude

    private init() {
        load()
        Task { await refreshAll() }
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: Self.configFile.path) else { return }
            let data = try Data(contentsOf: Self.configFile)
            let config = try JSONDecoder().decode(RavenConfig.self, from: data)
            providers = config.providers
            windowOverrides = config.windowOverrides
            selectedProviderID = config.selectedProviderID ?? providers.first?.id
            selectedModelID = config.selectedModelID
            if let client = config.selectedClient,
               let kind = ProviderKind(rawValue: client) {
                selectedClient = kind
            }
        } catch {
            NSLog("raven: could not read config: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try Self.ensureConfigDirectory()
            let config = RavenConfig(
                providers: providers,
                windowOverrides: windowOverrides,
                selectedProviderID: selectedProviderID,
                selectedModelID: selectedModelID,
                selectedClient: selectedClient.rawValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: Self.configFile, options: [.atomic])
        } catch {
            NSLog("raven: could not save config: \(error.localizedDescription)")
        }
    }

    func addProvider(name: String, baseURL: String, apiKey: String) {
        let provider = Provider(name: name.isEmpty ? "Provider" : name,
                                baseURL: baseURL,
                                apiKey: apiKey)
        providers.append(provider)
        if selectedProviderID == nil {
            selectedProviderID = provider.id
        }
        persist()
        Task { await refresh(provider) }
    }

    func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
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

    var selectedProvider: Provider? {
        providers.first { $0.id == selectedProviderID }
    }

    var selectedModels: [ModelEntry] {
        guard let id = selectedProviderID else { return [] }
        return models[id] ?? []
    }

    func windowOverride(providerID: UUID, modelID: String) -> Int? {
        windowOverrides.first {
            Self.matches($0, providerID: providerID, modelID: modelID)
        }?.contextWindow
    }

    func setWindowOverride(providerID: UUID, modelID: String, contextWindow: Int?) {
        windowOverrides.removeAll {
            Self.matches($0, providerID: providerID, modelID: modelID)
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
        if let override = windowOverride(providerID: providerID, modelID: modelID) {
            return override
        }
        return models[providerID]?.first { $0.modelID == modelID }?.contextWindow
    }

    private static func matches(_ override: ModelWindowOverride,
                                providerID: UUID, modelID: String) -> Bool {
        override.providerID == providerID && override.modelID == modelID
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
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
        }

        do {
            let entries = try await ModelsClient.fetch(provider: provider)
            models[provider.id] = entries
            return true
        } catch {
            models[provider.id] = []
            errors[provider.id] = error.localizedDescription
            return false
        }
    }
}
