import SwiftUI

struct LaunchBar: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Target()
            Spacer(minLength: 12)
            Picker("Client", selection: $store.client) {
                ForEach(ProviderKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Which client to start")

            WorkdirMenu()

            Button {
                workspace.launch()
            } label: {
                Label(workspace.isLaunching ? "Launching…" : "Launch", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canLaunch || workspace.isLaunching)
            .help("Open Terminal and start \(store.client.displayName) (⌘↩)")

            OverflowMenu()
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct Target: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        if let item = store.selectedItem {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.entry.modelID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(item.provider.name) · \(ContextWindow.label(store.effectiveWindow(item)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: item.entry.family.symbol)
                    .foregroundStyle(item.entry.family.tint)
            }
            .help("Launching \(item.entry.modelID) from \(item.provider.name)")
        } else {
            Text("Select a model to launch")
                .foregroundStyle(.secondary)
        }
    }
}

struct WorkdirMenu: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            Section("Recent Folders") {
                ForEach(store.recentWorkdirs.filter { $0 != store.workdir }, id: \.self) { url in
                    Button(url.lastPathComponent, systemImage: "folder") {
                        store.workdir = url
                    }
                }
            }
            Button("Home", systemImage: "house") {
                store.workdir = .homeDirectory
            }
            Divider()
            Button("Choose Folder…", systemImage: "folder.badge.plus") {
                workspace.chooseWorkdir()
            }
            Button("Show in Finder", systemImage: "magnifyingglass") {
                workspace.revealWorkdir()
            }
        } label: {
            Label(store.workdirLabel, systemImage: "folder")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Launch in \(store.workdirPath) (⇧⌘O to change)")
    }
}

struct OverflowMenu: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button(workspace.didCopyScript ? "Copied" : "Copy Launch Script",
                   systemImage: workspace.didCopyScript ? "checkmark" : "document.on.document") {
                workspace.copyScript()
            }
            .disabled(!store.canLaunch)
            Button("Show Launch Script…", systemImage: "apple.terminal") {
                workspace.isShowingScript = true
            }
            .disabled(!store.canLaunch)
            Divider()
            Button("Show Configuration in Finder", systemImage: "magnifyingglass") {
                workspace.revealConfig()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Launch script and configuration")
    }
}
