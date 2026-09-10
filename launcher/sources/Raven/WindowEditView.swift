import SwiftUI

struct WindowEditView: View {
    let context: ContentView.WindowEditContext
    let onSave: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var windowText = ""
    @State private var useAdvertised = false

    private let presets = [128_000, 200_000, 256_000, 400_000, 1_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context Window")
                        .font(.title2.bold())
                    Text(context.modelID)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Toggle("Use the value the provider advertises", isOn: $useAdvertised)

            if !useAdvertised {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tokens")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. 200000", text: $windowText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { preset in
                            Button(ContentView.windowLabel(preset)) {
                                windowText = String(preset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Label("This only sets where the client's context bar fills up and auto-compaction fires. It never caps what gets sent upstream.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 420)
        .padding(22)
        .onAppear {
            windowText = String(context.current ?? Launcher.fallbackContextWindow)
        }
    }

    private func save() {
        if useAdvertised {
            onSave(nil)
        } else if let window = Int(windowText.trimmingCharacters(in: .whitespaces)),
                  window > 0 {
            onSave(window)
        } else {
            dismiss()
            return
        }
        dismiss()
    }
}
