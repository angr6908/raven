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
    var name: String
    var baseURL: String
    var apiKey: String
    var validationMessage: String?
    var revealKey = false
    var testState: TestState = .idle

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

    var canTest: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && testState != .testing
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
        validationMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return Provider(id: id,
                        name: trimmedName.isEmpty ? "Provider" : trimmedName,
                        baseURL: url,
                        apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }

    func testConnection() {
        guard let provider = validated() else { return }
        testState = .testing
        Task {
            do {
                let entries = try await ModelsClient.fetch(provider: provider)
                testState = .success(entries.count)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
