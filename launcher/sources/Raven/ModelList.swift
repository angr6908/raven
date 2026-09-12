import SwiftUI

struct ModelList: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var store = store
        if let provider = workspace.focusedProvider, let error = store.error(for: provider) {
            ProviderError(provider: provider, message: error)
        } else if store.isRefreshing && store.modelCount == 0 {
            ProgressView("Loading models…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.isSearching && workspace.isEmptyResult {
            ContentUnavailableView.search(text: workspace.search)
        } else if workspace.isEmptyResult {
            EmptyDestination()
        } else {
            List(selection: $store.selection) {
                ForEach(workspace.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ModelItemRow(item: item)
                                .tag(item.ref)
                        }
                    } header: {
                        SectionHeader(section: section)
                    }
                }
            }
            .contextMenu(forSelectionType: ModelRef.self) { refs in
                if let item = refs.first.flatMap(store.item) {
                    ModelMenu(item: item)
                }
            } primaryAction: { refs in
                if let item = refs.first.flatMap(store.item) {
                    workspace.launch(item)
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
    }
}

struct SectionHeader: View {
    @Environment(ProviderStore.self) private var store
    let section: ModelSection

    var body: some View {
        HStack(spacing: 0) {
            switch section.kind {
            case .provider(let provider):
                Label {
                    Text(provider.name)
                } icon: {
                    Image(systemName: "server.rack")
                        .foregroundStyle(provider.accent)
                }
            case .owner(let owner):
                Text(owner)
            }
            Spacer()
            Text(section.items.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

struct ModelItemRow: View {
    @Environment(ProviderStore.self) private var store
    let item: ModelItem

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(item.entry.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: item.entry.family.symbol)
                    .foregroundStyle(item.entry.family.tint)
            }
            Spacer(minLength: 8)
            if store.isPinned(item) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Pinned")
            }
            ContextWindowLabel(badge: store.windowBadge(for: item))
        }
    }
}

struct ContextWindowLabel: View {
    let badge: WindowBadge

    var body: some View {
        HStack(spacing: 3) {
            if badge.isOverride {
                Image(systemName: "slider.horizontal.3")
            }
            Text(badge.label)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(badge.isOverride ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(badge.isOverride
              ? "Context window set by you — where the client's context bar fills and auto-compaction fires"
              : "Context window reported by the provider")
    }
}

struct ModelMenu: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace
    let item: ModelItem

    var body: some View {
        Button("Launch \(store.client.displayName)", systemImage: "play.fill") {
            workspace.launch(item)
        }
        Divider()
        Button(store.isPinned(item) ? "Unpin" : "Pin",
               systemImage: store.isPinned(item) ? "pin.slash" : "pin") {
            store.togglePin(item)
        }
        Button("Set Context Window…", systemImage: "slider.horizontal.3") {
            workspace.beginEditingWindow(item)
        }
        if store.windowBadge(for: item).isOverride {
            Button("Use Reported Window", systemImage: "arrow.uturn.backward") {
                workspace.setWindow(item, tokens: nil)
            }
        }
        Divider()
        Button("Copy Model ID", systemImage: "document.on.document") {
            workspace.copy(item.entry.modelID)
        }
    }
}

struct EmptyDestination: View {
    @Environment(ProviderStore.self) private var store
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch workspace.destination {
        case .pinned:
            ContentUnavailableView {
                Label("No pinned models", systemImage: "pin")
            } description: {
                Text("Pin the models you reach for most and they'll collect here.")
            }
        case .provider(let id):
            ContentUnavailableView {
                Label("No models", systemImage: "tray")
            } description: {
                Text("\(store.provider(id: id)?.name ?? "This provider") returned an empty model list.")
            } actions: {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if let provider = store.provider(id: id) {
                        workspace.refresh(provider)
                    }
                }
                .buttonStyle(.glass)
            }
        default:
            ContentUnavailableView {
                Label("No models", systemImage: "tray")
            } description: {
                Text("None of your providers returned any models.")
            } actions: {
                Button("Refresh All", systemImage: "arrow.clockwise") {
                    workspace.refreshAll()
                }
                .buttonStyle(.glass)
            }
        }
    }
}

struct ProviderError: View {
    @Environment(Workspace.self) private var workspace
    let provider: Provider
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't reach \(provider.name)", systemImage: "wifi.exclamationmark")
        } description: {
            Text("\(message)\n\(provider.modelsURL)")
                .monospaced()
                .textSelection(.enabled)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") {
                workspace.refresh(provider)
            }
            .buttonStyle(.glassProminent)
            Button("Edit Provider…") {
                workspace.edit(provider)
            }
            .buttonStyle(.glass)
        }
    }
}
