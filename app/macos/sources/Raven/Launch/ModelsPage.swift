import SwiftUI

struct ModelsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    @AppStorage("models.grouping") private var grouping = ModelGrouping.provider
    @AppStorage("models.sort") private var sort = ModelSort.name

    var body: some View {
        @Bindable var app = app
        let groups = app.groups(on: app.page, grouping: grouping, sort: sort)
        content(groups)
            .navigationTitle(app.title(for: app.page))
            .navigationSubtitle(subtitle(groups))
            .searchable(text: $app.search, placement: .toolbar, prompt: "Search models")
            .launchChrome()
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
        if let provider = app.focusedProvider, let message = store.error(for: provider) {
            EmptyState(symbol: "wifi.exclamationmark",
                       title: "Couldn't Reach \(provider.name)",
                       message: message) {
                HStack {
                    Button("Try Again") { app.refresh(provider) }
                        .buttonStyle(.glassProminent)
                    Button("Edit Provider…") { app.edit(provider) }
                        .buttonStyle(.glass)
                }
            }
        } else if store.isRefreshing && store.modelCount == 0 {
            LoadingState(message: "Loading models…")
        } else if groups.isEmpty {
            if app.isSearching {
                ContentUnavailableView.search(text: app.search)
            } else {
                emptyState
            }
        } else {
            ModelList(groups: groups, showsProvider: grouping != .provider && store.providers.count > 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch app.page {
        case .pinned:
            EmptyState(symbol: "pin", title: "No Pinned Models",
                       message: "Pin the models you reach for most and they'll collect here.")
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

    private func subtitle(_ groups: [ModelGroup]) -> String {
        let shown = groups.reduce(0) { $0 + $1.items.count }
        if app.isSearching { return shown == 1 ? "1 match" : "\(shown) matches" }
        return shown == 1 ? "1 model" : "\(shown) models"
    }
}

private struct ModelList: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    let groups: [ModelGroup]
    let showsProvider: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ModelRow(item: item, showsProvider: showsProvider).tag(item.ref)
                    }
                } header: {
                    if !group.title.isEmpty { Text(group.title) }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ModelRef.self) { refs in
            if let item = refs.first.flatMap({ store.item($0) }) {
                ModelMenu(item: item)
            }
        } primaryAction: { refs in
            if let ref = refs.first { app.launch(ref) }
        }
    }

    private var selection: Binding<ModelRef?> {
        Binding(get: { store.selection }, set: { store.selection = $0 })
    }
}

private struct ModelRow: View {
    @Environment(ProviderStore.self) private var store
    let item: ModelItem
    let showsProvider: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            FamilyGlyph(family: item.entry.family, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.modelID)
                    .font(.identifier)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsProvider {
                    Text(item.provider.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.sm)
            if store.isPinned(item) {
                Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange)
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
