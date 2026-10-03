import SwiftUI

struct ProviderSheet: View {
    @Bindable var draft: ProviderDraft
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing3) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    FormLabel(text: "Name")
                    TextField("My provider", text: $draft.name)
                }
                GridRow {
                    FormLabel(text: "Base URL")
                    TextField(LocalProxy.baseURL, text: $draft.baseURL)
                }
                GridRow {
                    FormLabel(text: "API Key")
                    HStack(spacing: 6) {
                        if draft.revealKey {
                            TextField("Optional", text: $draft.apiKey)
                        } else {
                            SecureField("Optional", text: $draft.apiKey)
                        }
                        Button {
                            draft.revealKey.toggle()
                        } label: {
                            Image(systemName: draft.revealKey ? "eye.slash" : "eye")
                        }
                        .help(draft.revealKey ? "Hide key" : "Reveal key")
                    }
                }
            }

            Divider()

            SectionHeader(title: "Connection")
            HStack(spacing: 8) {
                ProviderSheetConnectionStatus(state: draft.testState)
                Spacer()
                Button("Test") { draft.testConnection() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!draft.canTest)
            }

            if let message = draft.validationMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Text("Raven reads models from \(draft.fetchPreview)")
                .font(RavenFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isEditing ? "Save" : "Add") { commit() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.spacing5)
        .frame(width: 520)
    }

    private func commit() {
        guard draft.validated() != nil else { return }
        workspace.commitProviderDraft(draft)
        dismiss()
    }
}

private struct ProviderSheetConnectionStatus: View {
    let state: ProviderDraft.TestState

    var body: some View {
        switch state {
        case .idle:
            Label("Not tested", systemImage: "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .success(let count):
            Label(count == 1 ? "1 model" : "\(count) models", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
        }
    }
}
