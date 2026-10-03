import SwiftUI

struct RecentsView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Group {
            if store.recents.isEmpty {
                EmptyState(symbol: "clock",
                           title: "No launches yet",
                           message: "Every model you launch shows up here so you can pick up where you left off.")
            } else if workspace.visibleRecents.isEmpty {
                RecentsNoMatches(search: workspace.search)
            } else {
                RecentsList(recents: workspace.visibleRecents, store: store, workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { RecentsToolbar(store: store) }
    }
}

struct RecentsToolbar: View {
    let store: ProviderStore

    var body: some View {
        HStack {
            Spacer()
            Button {
                store.clearRecents()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.recents.isEmpty)
            .help("Forget every recent launch")
        }
        .padding(.horizontal, Metrics.spacing5)
        .padding(.vertical, Metrics.spacing2)
    }
}

struct RecentsNoMatches: View {
    let search: String

    var body: some View {
        EmptyState(symbol: "magnifyingglass",
                   title: "No matches",
                   message: "No launches match “\(search)”.")
    }
}

struct RecentsList: View {
    let recents: [RecentLaunch]
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(recents) { recent in
                    RecentRowView(recent: recent, store: store, workspace: workspace)
                }
            }
            .padding(.vertical, Metrics.spacing2)
        }
        .swipeActionsContainer()
    }
}

struct RecentRowView: View {
    let recent: RecentLaunch
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        RecentRowContent(recent: recent,
                         provider: store.provider(id: recent.providerID),
                         workspace: workspace)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { workspace.relaunch(recent) } label: {
                    Label("Launch Again", systemImage: "play.fill")
                }
                .tint(.accentColor)
                Button { workspace.restore(recent) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.secondary)
            }
            .contextMenu { RecentRowMenu(recent: recent, workspace: workspace) }
    }
}

struct RecentRowContent: View {
    let recent: RecentLaunch
    let provider: Provider?
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            TintedIcon(symbol: recent.client.symbol,
                       tint: provider.map(RavenTheme.providerAccent) ?? .secondary,
                       size: Metrics.familyIconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(recent.modelID)
                    .font(RavenFont.mono(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(provider?.name ?? "Removed provider") · \(recent.client.displayName) · \(recent.folderName)")
                    .font(RavenFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(recent.date, format: .relative(presentation: .named))
                .font(RavenFont.caption)
                .foregroundStyle(.secondary)

            Button {
                workspace.relaunch(recent)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Launch this again")
            .disabled(provider == nil || workspace.isLaunching)
        }
        .padding(.horizontal, Metrics.spacing4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(recent.workdir)
    }
}

struct RecentRowMenu: View {
    let recent: RecentLaunch
    let workspace: Workspace

    var body: some View {
        Button("Launch Again") { workspace.relaunch(recent) }
        Button("Restore Selection") { workspace.restore(recent) }
        Divider()
        Button("Copy Model ID") { workspace.copy(recent.modelID) }
    }
}
