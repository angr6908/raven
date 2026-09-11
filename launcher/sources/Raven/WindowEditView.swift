import SwiftUI

struct WindowEditView: View {
    @Bindable var draft: WindowDraft
    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use the value the provider advertises", isOn: $draft.useAdvertised)
                    if !draft.useAdvertised {
                        TextField("Tokens", text: $draft.text, prompt: Text("200000"))
                            .monospaced()
                        HStack(spacing: 6) {
                            ForEach(ContextWindow.presets, id: \.self) { preset in
                                Button(ContextWindow.label(preset)) {
                                    draft.text = String(preset)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text(draft.modelID)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                } footer: {
                    Label("This only sets where the client's context bar fills up and auto-compaction fires. It never caps what gets sent upstream.",
                          systemImage: "info.circle")
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
                        store.commitWindowDraft()
                    }
                }
            }
        }
        .frame(width: 460, height: 300)
    }
}
