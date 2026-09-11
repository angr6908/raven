import Foundation
import Observation

@Observable
final class ProviderDraft: Identifiable {
    let id: UUID
    let isEditing: Bool
    var name: String
    var baseURL: String
    var apiKey: String
    var validationMessage: String?

    init() {
        id = UUID()
        isEditing = false
        name = ""
        baseURL = ""
        apiKey = ""
    }

    init(_ provider: Provider) {
        id = provider.id
        isEditing = true
        name = provider.name
        baseURL = provider.baseURL
        apiKey = provider.apiKey
    }

    var fetchPreview: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "<base URL>/v1/models" }
        return Provider(name: name, baseURL: trimmed, apiKey: apiKey).modelsURL
    }

    func validated() -> Provider? {
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
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return Provider(id: id,
                        name: trimmedName.isEmpty ? "Provider" : trimmedName,
                        baseURL: url,
                        apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }
}

@Observable
final class WindowDraft: Identifiable {
    let providerID: UUID
    let modelID: String
    var text: String
    var useAdvertised = false

    var id: String { "\(providerID)/\(modelID)" }

    init(providerID: UUID, modelID: String, current: Int?) {
        self.providerID = providerID
        self.modelID = modelID
        text = String(current ?? ContextWindow.fallback)
    }

    var tokens: Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }
}
