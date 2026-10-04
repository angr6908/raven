import SwiftUI

struct ProviderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: ProviderDraft

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name", text: $draft.name, prompt: Text("My provider"))
                    TextField("Base URL", text: $draft.baseURL, prompt: Text(LocalProxy.baseURL))
                        .font(.identifier)
                    LabeledContent("API Key") {
                        HStack(spacing: Space.sm) {
                            Group {
                                if draft.revealKey {
                                    TextField("API Key", text: $draft.apiKey, prompt: Text("Optional"))
                                } else {
                                    SecureField("API Key", text: $draft.apiKey, prompt: Text("Optional"))
                                }
                            }
                            .labelsHidden()
                            .font(.identifier)
                            Button {
                                draft.revealKey.toggle()
                            } label: {
                                Image(systemName: draft.revealKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(draft.revealKey ? "Hide key" : "Reveal key")
                        }
                    }
                }

                Section {
                    HStack {
                        ConnectionStatus(state: draft.testState)
                        Spacer()
                        Button("Test Connection") { draft.testConnection() }
                            .disabled(!draft.canTest)
                    }
                    if let message = draft.validationMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Raven reads models from \(draft.fetchPreview)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isEditing ? "Edit Provider" : "Add Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isEditing ? "Save" : "Add") { app.commit(draft) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 520, height: 430)
    }
}

private struct ConnectionStatus: View {
    let state: ProviderDraft.TestState

    var body: some View {
        switch state {
        case .idle:
            Label("Not tested", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success(let count):
            Label(count == 1 ? "Connected · 1 model" : "Connected · \(count) models",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }
}

struct ScriptSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(store.launchScript() ?? "")
                    .font(.script)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle("Launch Script")
            .navigationSubtitle(store.selectedItem?.entry.modelID ?? "")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(app.copiedScript ? "Copied" : "Copy",
                           systemImage: app.copiedScript ? "checkmark" : "document.on.document") {
                        app.copyScript()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 680, height: 480)
    }
}
