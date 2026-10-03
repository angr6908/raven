import SwiftUI

struct LaunchInspectorView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            target
            Divider()
            clientPicker
            folderControl
            launchButton
        }
        .padding(Metrics.spacing4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var target: some View {
        if let item = store.selectedItem {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: item.entry.family.symbol)
                        .foregroundStyle(RavenTheme.familyTint(item.entry.family))
                    Text(item.entry.modelID)
                        .font(RavenFont.mono(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("\(item.provider.name) · \(ContextWindow.label(store.effectiveWindow(item)))")
                    .font(RavenFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Button(store.isPinned(item) ? "Unpin" : "Pin") { store.togglePin(item) }
                        .controlSize(.small)
                    Button("Context Window…") { workspace.beginEditingWindow(item) }
                        .controlSize(.small)
                }
                .buttonStyle(.glass)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a model to launch")
                    .font(RavenFont.body)
                    .foregroundStyle(.secondary)
                Text("Pick a model from the list to see its launch details here.")
                    .font(RavenFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var clientPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel(text: "Client")
            Picker("Client", selection: clientBinding) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var clientBinding: Binding<ProviderKind> {
        Binding(get: { store.client }, set: { store.client = $0 })
    }

    private var folderControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel(text: "Folder")
            Menu {
                let recents = store.recentWorkdirs.filter { $0 != store.workdir }
                if !recents.isEmpty {
                    Section("Recent Folders") {
                        ForEach(recents, id: \.path) { url in
                            Button(url.lastPathComponent) { select(url) }
                        }
                    }
                }
                Button("Home") { select(.homeDirectory) }
                Divider()
                Button("Choose Folder…") { workspace.chooseWorkdir() }
                Button("Show in Finder") { workspace.revealWorkdir() }
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(store.workdirLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            .menuStyle(.button)
            .help("Launch in \(store.workdirPath) (⇧⌘O to change)")
        }
    }

    private var launchButton: some View {
        Button {
            workspace.launch()
        } label: {
            Label(workspace.isLaunching ? "Launching…" : "Launch", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!store.canLaunch || workspace.isLaunching)
        .help("Open Terminal and start the selected model (⌘↩)")
    }

    private func select(_ url: URL) {
        store.workdir = url
        store.rememberWorkdir()
    }
}
