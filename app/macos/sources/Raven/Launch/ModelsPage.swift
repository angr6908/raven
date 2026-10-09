import SwiftUI

struct ModelsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    private let panel = ProvidersPanelStore.shared
    @AppStorage("models.grouping") private var grouping = ModelGrouping.provider
    @AppStorage("models.sort") private var sort = ModelSort.name

    var body: some View {
        @Bindable var app = app
        let groups = app.groups(on: app.page, grouping: grouping, sort: sort)
        content(groups)
            .navigationTitle(app.title(for: app.page))
            .searchable(text: $app.search, placement: .toolbar, prompt: "Search models")
            .launchChrome()
            .routedChrome(app.focusedSource)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Group By", selection: $grouping) {
                        ForEach(ModelGrouping.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Group models by provider or model family")
                }
            }
    }

    @ViewBuilder
    private func content(_ groups: [ModelGroup]) -> some View {
        if app.focusedSource != nil, panel.providers == nil {
            if let error = panel.error {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Load Providers", message: error) {
                    Button("Try Again") { panel.reload() }
                }
            } else {
                LoadingState(message: "Loading providers…")
            }
        } else if let provider = app.focusedProvider, let message = store.error(for: provider) {
            EmptyState(symbol: "wifi.exclamationmark",
                       title: "Couldn't Reach \(provider.name)",
                       message: message) {
                HStack {
                    Button("Try Again") { app.refresh(provider) }
                        .buttonStyle(.glassProminent)
                    if !provider.isBuiltIn {
                        Button("Edit Provider…") { app.edit(provider) }
                            .buttonStyle(.glass)
                    }
                }
            }
        } else if app.focusedSource == nil, store.isRefreshing && store.modelCount == 0 {
            LoadingState(message: "Loading models…")
        } else if groups.isEmpty {
            if app.isSearching {
                ContentUnavailableView.search(text: app.search)
            } else {
                emptyState
            }
        } else {
            ModelList(groups: groups, source: app.focusedSource,
                      showsProvider: grouping != .provider && app.focusedSource == nil && app.focusedProvider == nil)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch app.page {
        case .pinned:
            EmptyState(symbol: "pin", title: "No Pinned Models",
                       message: "Pin the models you reach for most and they'll collect here.")
        case .source(let source):
            if panel.syncing.contains(source) {
                LoadingState(message: "Fetching the catalog…")
            } else if let message = panel.syncErrors[source] {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Fetch the Catalog", message: message) {
                    Button("Try Again") { panel.sync(source) }
                }
            } else if case .provider(let id) = source, panel.blocked(source) {
                EmptyState(symbol: "exclamationmark.triangle", title: "Connection Incomplete",
                           message: "Finish the connection to load this provider's catalog.") {
                    Button("Edit…") { app.edit(upstream: id) }
                }
            } else {
                EmptyState(symbol: "tray", title: "No Models",
                           message: "\(panel.title(of: source))'s catalog returned no models.") {
                    Button("Try Again") { panel.sync(source) }
                }
            }
        case .provider:
            EmptyState(symbol: "tray", title: "No Models",
                       message: "\(app.focusedProvider?.name ?? "This provider") returned an empty model list.") {
                Button("Refresh") {
                    if let provider = app.focusedProvider { app.refresh(provider) }
                }
            }
        default:
            EmptyState(symbol: "tray", title: "No Models",
                       message: "None of your providers returned any models.") {
                Button("Refresh All") { app.refreshAll() }
            }
        }
    }
}

private struct ModelList: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    private let panel = ProvidersPanelStore.shared
    let groups: [ModelGroup]
    let source: RouteSource?
    let showsProvider: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ModelRow(item: item, showsProvider: showsProvider, source: source, status: status(item))
                            .tag(item.ref)
                    }
                } header: {
                    if !group.title.isEmpty { Text(group.title) }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ModelRef.self) { refs in
            if let ref = refs.first, let item = groups.lazy.flatMap(\.items).first(where: { $0.ref == ref }) {
                ModelMenu(item: item)
                if let source { RoutedModelMenu(source: source, item: item) }
            }
        } primaryAction: { refs in
            if let ref = refs.first { app.launch(ref) }
        }
    }

    private func status(_ item: ModelItem) -> RouteStatus? {
        guard let source, let index = panel.modelIndex(source, clientID: item.entry.modelID) else { return nil }
        return panel.status(source, model: index)
    }

    private var selection: Binding<ModelRef?> {
        Binding(get: { store.selection }, set: { store.selection = $0 })
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    let item: ModelItem
    let showsProvider: Bool
    let source: RouteSource?
    let status: RouteStatus?

    var body: some View {
        HStack(spacing: Space.md) {
            FamilyGlyph(family: item.entry.family, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.modelID)
                    .font(.identifier)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsProvider {
                    Text(app.providerTitle(item)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.sm)
            if let status, status.isProblem {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .help("\(status.title). \(status.explanation)")
            }
            if store.isPinned(item) {
                Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange)
            }
            if let source {
                ReasoningBadge(source: source, item: item)
            }
            Text(store.windowBadge(for: item).label.replacingOccurrences(of: " ctx", with: ""))
                .font(.figure)
                .foregroundStyle(store.windowBadge(for: item).isOverride ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    let item: ModelItem

    var body: some View {
        Button("Launch \(store.client.displayName)", systemImage: "play.fill") { app.launch(item) }
        Divider()
        Button(store.isPinned(item) ? "Unpin" : "Pin", systemImage: store.isPinned(item) ? "pin.slash" : "pin") {
            store.togglePin(item)
        }
        Divider()
        Button("Copy Model ID", systemImage: "document.on.document") { app.copy(item.entry.modelID) }
        Button(app.copiedScript ? "Copied" : "Copy Launch Script", systemImage: "terminal") {
            app.select(item)
            app.copyScript()
        }
        Button("Show Launch Script…", systemImage: "doc.text") {
            app.select(item)
            app.sheet = .script
        }
    }
}
