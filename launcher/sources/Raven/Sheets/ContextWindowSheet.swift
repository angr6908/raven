import SwiftUI

struct ContextWindowSheet: View {
    @Bindable var draft: WindowDraft
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing3) {
            Text(draft.modelID)
                .font(RavenFont.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if draft.advertised != nil {
                Toggle("Use the window the provider reports", isOn: $draft.useAdvertised)
            }

            if !draft.useAdvertised {
                TextField("200000", text: $draft.text)
                    .font(RavenFont.numeric(12))

                Picker("Presets", selection: presetBinding) {
                    ForEach(Array(ContextWindow.presets.enumerated()), id: \.offset) { _, preset in
                        Text(ContextWindow.compact(preset)).tag(ContextWindow.presets.firstIndex(of: preset) ?? -1)
                    }
                    Text("Custom").tag(ContextWindow.presets.count)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("Effective")
                    .font(.system(size: 12, weight: .medium))
                if let preview = draft.preview {
                    Text(preview)
                        .font(RavenFont.numeric(12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enter a positive number")
                        .font(RavenFont.numeric(12))
                        .foregroundStyle(.red)
                }
            }

            Text("Sets where the client's context bar fills and auto-compaction fires. Nothing is capped upstream.")
                .font(RavenFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(Metrics.spacing5)
        .frame(width: 470)
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: {
                guard let tokens = draft.tokens,
                      let index = ContextWindow.presets.firstIndex(of: tokens) else {
                    return ContextWindow.presets.count
                }
                return index
            },
            set: { index in
                guard index >= 0, index < ContextWindow.presets.count else { return }
                draft.text = String(ContextWindow.presets[index])
            })
    }

    private func commit() {
        workspace.commitWindowDraft(draft)
        dismiss()
    }
}
