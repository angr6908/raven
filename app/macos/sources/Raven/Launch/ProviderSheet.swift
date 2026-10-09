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
                    TextField("Base URL", text: $draft.baseURL,
                              prompt: Text(verbatim: draft.viaRaven ? "https://api.example.com/v1" : LocalProxy.baseURL))
                        .font(.identifier)
                    LabeledContent("API Key") {
                        HStack(spacing: Space.sm) {
                            Group {
                                if draft.revealKey {
                                    TextField("API Key", text: $draft.apiKey, prompt: Text(keyPrompt))
                                } else {
                                    SecureField("API Key", text: $draft.apiKey, prompt: Text(keyPrompt))
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
                    Toggle("Route through Raven", isOn: $draft.viaRaven)
                    if draft.viaRaven {
                        Picker("Protocol", selection: $draft.kind) {
                            Text("Chat Completions").tag("openai")
                            Text("Responses").tag("responses")
                        }
                    }
                } footer: {
                    Text(routingNote)
                }

                if draft.viaRaven {
                    Section("Spare Keys") {
                        ForEach(draft.spareKeys.indices, id: \.self) { index in
                            SpareKeyRow(draft: draft, index: index)
                        }
                        Button("Add Spare Key") { draft.spareKeys.append(ApiKeyEntry(apiKey: "")) }
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
        .frame(width: 520, height: 560)
    }

    private var keyPrompt: String {
        draft.viaRaven ? "sk-…" : "Optional"
    }

    private var routingNote: String {
        if draft.upstreamID != nil, !draft.viaRaven {
            return "Saving stops Raven from routing this provider, and its model list is removed."
        }
        if draft.isEditing, draft.upstreamID == nil, draft.viaRaven {
            return "Saving moves this provider into Raven, and its pins and context overrides are removed."
        }
        return draft.viaRaven
            ? "Raven translates requests for Claude Code and Codex."
            : "Claude Code and Codex connect to this endpoint directly, so it must speak their APIs."
    }
}

private struct SpareKeyRow: View {
    @Bindable var draft: ProviderDraft
    let index: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            Group {
                if draft.revealKey {
                    TextField("Spare Key \(index + 1)", text: binding, prompt: Text(verbatim: "sk-…"))
                } else {
                    SecureField("Spare Key \(index + 1)", text: binding, prompt: Text(verbatim: "sk-…"))
                }
            }
            .font(.identifier)
            Menu {
                Button("Make Active") { draft.makeActive(index) }
                Button("Remove Key", systemImage: "trash", role: .destructive) {
                    if draft.spareKeys.indices.contains(index) { draft.spareKeys.remove(at: index) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { draft.spareKeys.indices.contains(index) ? draft.spareKeys[index].apiKey : "" },
            set: { if draft.spareKeys.indices.contains(index) { draft.spareKeys[index].apiKey = $0 } })
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
