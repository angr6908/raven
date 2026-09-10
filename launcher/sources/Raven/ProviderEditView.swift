import SwiftUI

struct ProviderEditView: View {
    let isEditing: Bool
    var provider: Provider?

    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var validationMessage: String?

    private let urlPlaceholder = "https://api.example.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Provider" : "Add Provider")
                        .font(.title2.bold())
                    Text("An OpenAI-compatible endpoint Raven can list models from.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                field(title: "Name", systemImage: "tag") {
                    TextField("My provider", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                field(title: "Base URL", systemImage: "link") {
                    TextField(urlPlaceholder, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                field(title: "API Key", systemImage: "key") {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Raven will fetch ")
                    .foregroundColor(.secondary)
                    + Text(fetchPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 460)
        .padding(22)
        .onAppear {
            if let provider {
                name = provider.name
                baseURL = provider.baseURL
                apiKey = provider.apiKey
            }
        }
    }

    private func field<Content: View>(title: String,
                                      systemImage: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var fetchPreview: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "<base URL>/v1/models" }
        var root = trimmed
        while root.hasSuffix("/") { root.removeLast() }
        let v1 = root.hasSuffix("/v1") ? root : root + "/v1"
        return v1 + "/models"
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else {
            validationMessage = "Base URL is required"
            return
        }
        guard let scheme = URL(string: trimmedURL)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            validationMessage = "Base URL must start with http:// or https://"
            return
        }
        onSave(name.trimmingCharacters(in: .whitespaces), trimmedURL,
               apiKey.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
