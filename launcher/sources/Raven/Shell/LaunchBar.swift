import SwiftUI

struct LaunchBar: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        HStack(spacing: Metrics.spacing3) {
            LaunchTarget(store: store, workspace: workspace)
            Spacer(minLength: Metrics.spacing2)
            LaunchClientPicker(store: store)
            LaunchFolderMenu(store: store, workspace: workspace)
            LaunchActionButton(store: store, workspace: workspace)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, Metrics.contentMargin)
        .padding(.top, Metrics.spacing2)
        .padding(.bottom, Metrics.spacing3)
        .frame(maxWidth: .infinity)
    }
}

struct LaunchTarget: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        if let item = store.selectedItem {
            HStack(spacing: 8) {
                Image(systemName: item.entry.family.symbol)
                    .foregroundStyle(RavenTheme.familyTint(item.entry.family))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.entry.modelID)
                        .font(RavenFont.mono(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("\(item.provider.name) · \(ContextWindow.label(store.effectiveWindow(item)))")
                        .font(RavenFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
            .contextMenu {
                Button(store.isPinned(item) ? "Unpin" : "Pin") { store.togglePin(item) }
                Button("Set Context Window…") { workspace.beginEditingWindow(item) }
                Divider()
                Button("Copy Model ID") { workspace.copy(item.entry.modelID) }
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Select a model to launch")
                    .font(RavenFont.body)
                    .foregroundStyle(.secondary)
                Text("Pick a model from the list above.")
                    .font(RavenFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct LaunchClientPicker: View {
    let store: ProviderStore

    var body: some View {
        Picker("Client", selection: Binding(get: { store.client }, set: { store.client = $0 })) {
            ForEach(ProviderKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Which client to start")
    }
}

struct LaunchFolderMenu: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
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
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(store.workdirLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Launch in \(store.workdirPath) (⇧⌘O to change)")
    }

    private func select(_ url: URL) {
        store.workdir = url
        store.rememberWorkdir()
    }
}

struct LaunchActionButton: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Button {
            workspace.launch()
        } label: {
            Label(workspace.isLaunching ? "Launching…" : "Launch", systemImage: "play.fill")
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!store.canLaunch || workspace.isLaunching)
        .help("Open Terminal and start the selected model (⌘↩)")
    }
}
