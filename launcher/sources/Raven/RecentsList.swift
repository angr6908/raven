import SwiftUI

struct RecentsList: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        if store.recents.isEmpty {
            ContentUnavailableView {
                Label("No launches yet", systemImage: "clock")
            } description: {
                Text("Every model you launch shows up here so you can pick up where you left off.")
            }
        } else if workspace.visibleRecents.isEmpty {
            ContentUnavailableView.search(text: workspace.search)
        } else {
            List(selection: $store.selection) {
                ForEach(workspace.visibleRecents) { recent in
                    RecentRow(recent: recent)
                        .tag(recent.ref)
                        .contextMenu {
                            Button("Launch Again", systemImage: "play.fill") {
                                workspace.relaunch(recent)
                            }
                            Button("Restore Selection", systemImage: "arrow.uturn.backward") {
                                workspace.restore(recent)
                            }
                            Divider()
                            Button("Copy Model ID", systemImage: "document.on.document") {
                                workspace.copy(recent.modelID)
                            }
                        }
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .toolbar {
                ToolbarItem {
                    Button("Clear", systemImage: "trash") {
                        store.clearRecents()
                    }
                    .help("Forget every recent launch")
                }
            }
        }
    }
}

struct RecentRow: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace
    let recent: RecentLaunch

    var body: some View {
        let provider = store.provider(id: recent.providerID)
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.modelID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(provider?.name ?? "Removed provider") · \(recent.client.displayName) · \(recent.folderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: recent.client.symbol)
                    .foregroundStyle(provider?.accent ?? .secondary)
            }
            Spacer(minLength: 8)
            Text(recent.date, format: .relative(presentation: .numeric))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Launch Again", systemImage: "play.fill") {
                workspace.relaunch(recent)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(provider == nil || workspace.isLaunching)
            .help("Launch this again")
        }
        .help(recent.workdir)
    }
}
