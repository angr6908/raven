import SwiftUI

struct ProviderSheet: View {
    @Bindable var draft: ProviderDraft
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("My provider"))
                    TextField("Base URL", text: $draft.baseURL, prompt: Text(LocalProxy.baseURL))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("Optional"))
                } footer: {
                    Text("Raven reads models from \(Text(draft.fetchPreview).monospaced())")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Connection") {
                        HStack(spacing: 8) {
                            result
                            Button("Test") {
                                draft.testConnection()
                            }
                            .disabled(!draft.canTest)
                        }
                    }
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
                        workspace.commitProviderDraft()
                    }
                }
            }
        }
        .frame(width: 500, height: 340)
    }

    @ViewBuilder
    private var result: some View {
        switch draft.testState {
        case .idle:
            Text("Not tested")
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success(let count):
            Label(count == 1 ? "1 model" : "\(count) models", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
        }
    }
}

struct ContextWindowSheet: View {
    @Bindable var draft: WindowDraft
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.advertised != nil {
                        Toggle("Use the window the provider reports", isOn: $draft.useAdvertised)
                    }
                    if !draft.useAdvertised {
                        TextField("Tokens", text: $draft.text, prompt: Text("200000"))
                            .monospacedDigit()
                        Picker("Preset", selection: presetSelection) {
                            ForEach(ContextWindow.presets, id: \.self) { preset in
                                Text(ContextWindow.compact(preset)).tag(Optional(preset))
                            }
                            Text("Custom").tag(Optional<Int>.none)
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledContent("Effective") {
                        Text(draft.preview ?? "Enter a positive number")
                            .foregroundStyle(draft.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                            .monospacedDigit()
                    }
                } header: {
                    Text(draft.modelID)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                } footer: {
                    Text("Sets where the client's context bar fills and auto-compaction fires. Nothing is capped upstream.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Context Window")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        workspace.commitWindowDraft()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
        .frame(width: 470, height: 350)
    }

    private var presetSelection: Binding<Int?> {
        let draft = draft
        return Binding {
            ContextWindow.presets.first { $0 == draft.tokens }
        } set: { preset in
            if let preset { draft.text = String(preset) }
        }
    }
}

struct ScriptSheet: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(store.launchScript() ?? "")
                    .font(.callout)
                    .monospaced()
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Launch Script")
            .navigationSubtitle("Written to \(ProviderStore.configDirectory.path(percentEncoded: false))/launch.sh, then opened in Terminal")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(workspace.didCopyScript ? "Copied" : "Copy",
                           systemImage: workspace.didCopyScript ? "checkmark" : "document.on.document") {
                        workspace.copyScript()
                    }
                    .contentTransition(.symbolEffect(.replace))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", role: .cancel) { dismiss() }
                }
            }
        }
        .frame(width: 620, height: 460)
    }
}
