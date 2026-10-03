import SwiftUI

struct ModelListView: View {
    let store: ProviderStore
    let workspace: Workspace

    var body: some View {
        Group {
            if let provider = workspace.focusedProvider, let message = store.error(for: provider) {
                providerError(provider, message)
            } else if store.isRefreshing && store.modelCount == 0 {
                RavenLoader(message: "Loading models…")
            } else if workspace.isSearching && workspace.isEmptyResult {
                EmptyState(symbol: "magnifyingglass",
                           title: "No matches",
                           message: "No models match “\(workspace.search)”.")
            } else if workspace.isEmptyResult {
                emptyDestination
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(workspace.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ModelRowView(item: item, store: store, workspace: workspace)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding(.vertical, Metrics.spacing2)
        }
    }

    private func sectionHeader(_ section: ModelSection) -> some View {
        HStack(spacing: 6) {
            switch section.kind {
            case .provider(let provider):
                Image(systemName: "server.rack")
                    .foregroundStyle(RavenTheme.providerAccent(provider))
                    .imageScale(.small)
            case .owner:
                EmptyView()
            }
            SectionHeader(title: section.kind.title)
            Spacer()
            Pill(text: String(section.items.count))
        }
        .padding(.horizontal, Metrics.spacing4)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder
    private var emptyDestination: some View {
        switch workspace.destination {
        case .pinned:
            EmptyState(symbol: "pin",
                       title: "No pinned models",
                       message: "Pin the models you reach for most and they'll collect here.")
        case .provider(let id):
            let name = store.provider(id: id)?.name ?? "This provider"
            EmptyState(symbol: "tray", title: "No models", message: "\(name) returned an empty model list.") {
                Button("Refresh") {
                    if let provider = store.provider(id: id) { workspace.refresh(provider) }
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

    private func providerError(_ provider: Provider, _ message: String) -> some View {
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

            windowBadge
        }
        .padding(.horizontal, Metrics.spacing4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = item.ref }
        .onTapGesture(count: 2) { workspace.launch(item) }
        .onHover { hover.isHovering = $0 }
        .contextMenu { menu }
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

    private var windowBadge: some View {
        let badge = store.windowBadge(for: item)
        return HStack(spacing: 3) {
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

    @ViewBuilder
    private var menu: some View {
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
