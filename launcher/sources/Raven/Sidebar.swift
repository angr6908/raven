import SwiftUI

struct Sidebar: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        @Bindable var workspace = workspace
        List(selection: $workspace.destination) {
            Section {
                Label("All Models", systemImage: Destination.library.symbol)
                    .badge(store.modelCount)
                    .tag(Destination.library)
                Label("Pinned", systemImage: Destination.pinned.symbol)
                    .badge(store.pinned.count)
                    .tag(Destination.pinned)
                Label("Recents", systemImage: Destination.recents.symbol)
                    .badge(store.recents.count)
                    .tag(Destination.recents)
            }

            Section {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider)
                        .tag(Destination.provider(provider.id))
                        .contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                workspace.refresh(provider)
                            }
                            Button("Edit…", systemImage: "pencil") {
                                workspace.edit(provider)
                            }
                            Divider()
                            Button("Remove…", systemImage: "trash", role: .destructive) {
                                workspace.confirmRemoval(of: provider)
                            }
                        }
                }
                .onMove { source, destination in
                    store.moveProviders(from: source, to: destination)
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Providers")
                    Spacer()
                    Button("Add Provider", systemImage: "plus") {
                        workspace.addProvider()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add a provider (⌘N)")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 300)
    }
}

struct ProviderRow: View {
    @Environment(ProviderStore.self) private var store
    let provider: Provider

    var body: some View {
        let status = store.status(of: provider)
        Label {
            Text(provider.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: "server.rack")
                .foregroundStyle(provider.accent)
        }
        .badge(badge)
        .help("\(provider.host) · \(status.subtitle)")
    }

    private var badge: Text? {
        switch store.status(of: provider) {
        case .ready(let count): Text(count, format: .number)
        case .failed: Text(Image(systemName: "exclamationmark.triangle.fill"))
        case .loading, .empty: nil
        }
    }
}
