import SwiftUI

struct ProviderEditView: View {
    @Bindable var draft: ProviderDraft
    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("My provider"))
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com"))
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("sk-…"))
                } header: {
                    Text("An OpenAI-compatible endpoint Raven can list models from.")
                } footer: {
                    Label {
                        Text("Raven will fetch \(Text(draft.fetchPreview).monospaced())")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .foregroundStyle(.secondary)
                }
                if let message = draft.validationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isEditing ? "Edit Provider" : "Add Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isEditing ? "Save" : "Add", role: .confirm) {
                        store.commitProviderDraft()
                    }
                }
            }
        }
        .frame(width: 480, height: 330)
    }
}
