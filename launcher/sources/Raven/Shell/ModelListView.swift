import SwiftUI

struct ModelListView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Group {
            if let provider = workspace.focusedProvider, let message = store.error(for: provider) {
                ModelListProviderError(provider: provider, message: message, workspace: workspace)
            } else if store.isRefreshing && store.modelCount == 0 {
                RavenLoader(message: "Loading models…")
            } else if workspace.isSearching && workspace.isEmptyResult {
                ModelListNoMatches(search: workspace.search)
            } else if workspace.isEmptyResult {
                ModelListEmpty(destination: workspace.destination,
                               providerName: workspace.focusedProvider.map { store.provider(id: $0.id)?.name ?? "This provider" },
                               workspace: workspace)
            } else {
                ModelSectionedList(sections: workspace.sections, store: store, workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModelSectionedList: View {
    let sections: [ModelSection]
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ModelRowView(item: item, store: store, workspace: workspace)
                        }
                    } header: {
                        ModelSectionHeaderView(section: section)
                    }
                }
            }
            .padding(.vertical, Metrics.spacing2)
        }
        .swipeActionsContainer()
    }
}

struct ModelSectionHeaderView: View {
    let section: ModelSection

    var body: some View {
        HStack(spacing: 6) {
            if case .provider(let provider) = section.kind {
                Image(systemName: "server.rack")
                    .foregroundStyle(RavenTheme.providerAccent(provider))
                    .imageScale(.small)
            }
            SectionHeader(title: section.kind.title)
            Spacer()
            Pill(text: String(section.items.count))
        }
        .padding(.horizontal, Metrics.spacing4)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct ModelListProviderError: View {
    let provider: Provider
    let message: String
    let workspace: Workspace

    var body: some View {
        EmptyState(symbol: "wifi.exclamationmark",
                   title: "Couldn't reach \(provider.name)",
                   message: "\(message)\n\(provider.modelsURL)") {
            HStack {
                Button("Try Again") { workspace.refresh(provider) }
                    .buttonStyle(.glassProminent)
                Button("Edit Provider…") { workspace.edit(provider) }
                    .buttonStyle(.glass)
            }
        }
    }
}

struct ModelListNoMatches: View {
    let search: String

    var body: some View {
        EmptyState(symbol: "magnifyingglass",
                   title: "No matches",
                   message: "No models match “\(search)”.")
    }
}

struct ModelListEmpty: View {
    let destination: Destination
    let providerName: String?
    let workspace: Workspace

    var body: some View {
        switch destination {
        case .pinned:
            EmptyState(symbol: "pin",
                       title: "No pinned models",
                       message: "Pin the models you reach for most and they'll collect here.")
        case .provider:
            EmptyState(symbol: "tray", title: "No models",
                       message: "\(providerName ?? "This provider") returned an empty model list.") {
                Button("Refresh") {
                    if let provider = workspace.focusedProvider { workspace.refresh(provider) }
                }
            }
        default:
            EmptyState(symbol: "tray",
                       title: "No models",
                       message: "None of your providers returned any models.") {
                Button("Refresh All") { workspace.refreshAll() }
            }
        }
    }
}

@Observable
private final class RowHover {
    var isHovering = false
}

struct ModelRowView: View {
    let item: ModelItem
    let store: ProviderStore
    let workspace: Workspace

    @Bindable private var hover = RowHover()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.entry.family.symbol)
                .foregroundStyle(RavenTheme.familyTint(item.entry.family))
                .frame(width: 18)

            Text(item.entry.modelID)
                .font(RavenFont.mono(13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if store.isPinned(item) {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Pinned")
            }

            ModelWindowBadge(badge: store.windowBadge(for: item))
        }
        .padding(.horizontal, Metrics.spacing4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = item.ref }
        .onTapGesture(count: 2) { workspace.launch(item) }
        .onHover { hover.isHovering = $0 }
        .contextMenu { ModelRowMenu(item: item, store: store, workspace: workspace) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { workspace.launch(item) } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { store.togglePin(item) } label: {
                Label(store.isPinned(item) ? "Unpin" : "Pin",
                      systemImage: store.isPinned(item) ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if store.selection == item.ref {
            Color.accentColor.opacity(0.18)
        } else if hover.isHovering {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }
}

struct ModelWindowBadge: View {
    let badge: WindowBadge

    var body: some View {
        HStack(spacing: 3) {
            if badge.isOverride {
                Image(systemName: "slider.horizontal.3")
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
            }
            Text(badge.label)
                .font(RavenFont.numeric(11))
                .foregroundStyle(badge.isOverride ? Color.accentColor : .secondary)
        }
        .help(badge.isOverride
              ? "Context window set by you — where the client's context bar fills and auto-compaction fires"
              : "Context window reported by the provider")
    }
}

struct ModelRowMenu: View {
    let item: ModelItem
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Button("Launch \(store.client.displayName)") { workspace.launch(item) }
        Divider()
        Button(store.isPinned(item) ? "Unpin" : "Pin") { store.togglePin(item) }
        Button("Set Context Window…") { workspace.beginEditingWindow(item) }
        if store.windowBadge(for: item).isOverride {
            Button("Use Reported Window") { workspace.setWindow(item, tokens: nil) }
        }
        Divider()
        Button("Copy Model ID") { workspace.copy(item.entry.modelID) }
    }
}
