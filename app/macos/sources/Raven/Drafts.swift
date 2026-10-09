import Foundation
import Observation

@Observable
final class ProviderDraft: Identifiable {
    enum TestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    let id: UUID
    let isEditing: Bool
    let upstreamID: UUID?
    var name: String
    var baseURL: String
    var apiKey: String
    var activeKey = ApiKeyEntry(apiKey: "")
    var spareKeys: [ApiKeyEntry] = []
    var viaRaven: Bool {
        didSet { if viaRaven != oldValue { testState = .idle } }
    }
    var kind = "openai"
    var validationMessage: String?
    var revealKey = false
    var testState: TestState = .idle

    init() {
        id = UUID()
        isEditing = false
        upstreamID = nil
        name = ""
        baseURL = ""
        apiKey = ""
        viaRaven = true
    }

    init(_ provider: Provider) {
        id = provider.id
        isEditing = true
        upstreamID = nil
        name = provider.name
        baseURL = provider.baseURL
        apiKey = provider.apiKey
        viaRaven = false
    }

    init(upstream id: UUID, entry: ProviderEntry) {
        self.id = UUID()
        isEditing = true
        upstreamID = id
        name = entry.name
        baseURL = entry.baseUrl ?? ""
        apiKey = entry.apiKeyEntries.first?.apiKey ?? ""
        activeKey = entry.apiKeyEntries.first ?? ApiKeyEntry(apiKey: "")
        spareKeys = Array(entry.apiKeyEntries.dropFirst())
        viaRaven = true
        kind = entry.usableKind
    }

    func makeActive(_ index: Int) {
        guard spareKeys.indices.contains(index) else { return }
        var current = activeKey
        current.apiKey = apiKey
        let next = spareKeys.remove(at: index)
        spareKeys.insert(current, at: 0)
        activeKey = next
        apiKey = next.apiKey
    }

    var fetchPreview: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        if viaRaven {
            return (trimmed.isEmpty ? "<base URL>" : Self.trimmingSlashes(trimmed)) + "/models"
        }
        guard !trimmed.isEmpty else { return "<base URL>/v1/models" }
        return Provider(name: name, baseURL: trimmed, apiKey: apiKey).modelsURL
    }

    var canTest: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && testState != .testing
    }

    private func validatedURL() -> String? {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else {
            validationMessage = "Base URL is required"
            return nil
        }
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            validationMessage = "Base URL must start with http:// or https://"
            return nil
        }
        validationMessage = nil
        return url
    }

    func validated() -> Provider? {
        guard let url = validatedURL() else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return Provider(id: id,
                        name: trimmedName.isEmpty ? "Provider" : trimmedName,
                        baseURL: url,
                        apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }

    func routedEntry(taken: [String]) -> ProviderEntry? {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            validationMessage = "Name is required"
            return nil
        }
        guard !taken.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == title.lowercased() }) else {
            validationMessage = "Another provider already uses this name"
            return nil
        }
        guard let url = validatedURL() else { return nil }
        var active = activeKey
        active.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        var entry = PanelLogic.blankProviderEntry(kind: kind, name: title)
        entry.baseUrl = url
        entry.apiKeyEntries = [active] + spareKeys
        return entry
    }

    func testConnection() {
        guard let provider = validated() else { return }
        let routed = viaRaven
        testState = .testing
        Task {
            do {
                let entries = routed
                    ? try await ModelsClient.fetch(at: Self.trimmingSlashes(provider.baseURL) + "/models",
                                                   apiKey: provider.apiKey)
                    : try await ModelsClient.fetch(provider: provider)
                testState = .success(entries.count)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private static func trimmingSlashes(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
