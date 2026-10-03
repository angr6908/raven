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
                EmptyState(symbol: "magnifyingglass",
                           title: "No matches",
                           message: "No launches match “\(workspace.search)”.")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
    }

    private var toolbar: some View {
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workspace.visibleRecents) { recent in
                    RecentRowView(recent: recent, store: store, workspace: workspace)
                }
            }
            .padding(.vertical, Metrics.spacing2)
        }
    }
}

struct RecentRowView: View {
    let recent: RecentLaunch
    let store: ProviderStore
    let workspace: Workspace

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recent.client.symbol)
                .foregroundStyle(provider.map(RavenTheme.providerAccent) ?? .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(recent.modelID)
                    .font(RavenFont.mono(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(provider?.name ?? "Removed provider") · \(recent.client.displayName) · \(recent.folderName)")
                    .font(RavenFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(Self.relative.localizedString(for: recent.date, relativeTo: .now))
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
        .contextMenu {
            Button("Launch Again") { workspace.relaunch(recent) }
            Button("Restore Selection") { workspace.restore(recent) }
            Divider()
            Button("Copy Model ID") { workspace.copy(recent.modelID) }
        }
    }

    private var provider: Provider? { store.provider(id: recent.providerID) }
}
