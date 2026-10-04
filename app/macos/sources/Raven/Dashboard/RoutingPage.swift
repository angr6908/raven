import SwiftUI

enum SourceTab: String, CaseIterable, Identifiable {
    case models, connection

    var id: String { rawValue }
    var title: String { self == .models ? "Models" : "Connection" }
}

@Observable
final class RoutingNavigation {
    static let shared = RoutingNavigation()
    static let home = RouteSource.channel(ChannelSpec.all[0].kind)

    var selection: RouteSource = home
    var tab: SourceTab = .models
    var models: Set<Int> = []
    var catalog: RouteSource?
    var removing: UUID?

    func show(_ source: RouteSource) {
        selection = source
        tab = .models
        models = []
    }

    func open(_ source: RouteSource, tab: SourceTab) {
        selection = source
        self.tab = tab
        models = []
    }
}

extension RouteStatus {
    var tint: Color {
        switch self {
        case .active: Palette.good
        case .hidden: .secondary
        case .incomplete, .duplicate, .shadowed: .orange
        }
    }

    var symbol: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .hidden: "eye.slash"
        case .incomplete: "exclamationmark.triangle.fill"
        case .duplicate: "square.on.square"
        case .shadowed: "arrow.triangle.merge"
        }
    }
}

struct RoutingPage: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared

    var body: some View {
        @Bindable var nav = nav
        let rows = RoutingTable.rows(store.list)
        Group {
            if store.providers != nil {
                HStack(spacing: 0) {
                    SourceList(rows: rows)
                        .frame(width: 264)
                    Divider()
                    RoutingDetail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error = store.error {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Load Routing", message: error) {
                    Button("Try Again") { store.reload() }
                }
            } else {
                LoadingState(message: "Loading routes…")
            }
        }
        .navigationTitle("Routing")
        .navigationSubtitle(subtitle(rows))
        .toolbar { RoutingToolbar(loaded: store.providers != nil) }
        .sheet(item: $nav.catalog) { source in
            CatalogSheet(source: source)
        }
        .confirmationDialog("Remove this provider?", isPresented: Binding(
            get: { nav.removing != nil }, set: { if !$0 { nav.removing = nil } }), presenting: nav.removing) { id in
            Button("Remove \(store.entry(.provider(id)).map(RoutingTable.sourceName) ?? "Provider")", role: .destructive) {
                if nav.selection == .provider(id) { nav.show(RoutingNavigation.home) }
                store.remove(id)
            }
        } message: { id in
            let count = store.entry(.provider(id))?.models.count ?? 0
            Text(count == 0 ? "This can't be undone." : "Its \(count == 1 ? "model stops" : "\(count) models stop") routing.")
        }
        .onChange(of: store.ids) {
            if case .provider(let id) = nav.selection, !store.ids.contains(id) {
                nav.show(RoutingNavigation.home)
            }
        }
        .onChange(of: UsageStore.shared.isProxyUp) { _, up in
            if up, store.providers == nil { store.reload() }
        }
        .alert("Couldn't Reach models.dev", isPresented: Binding(
            get: { ModelFiller.shared.note != nil }, set: { if !$0 { ModelFiller.shared.dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ModelFiller.shared.note ?? "")
        }
        .onAppear { store.start() }
    }

    private func subtitle(_ rows: [RouteRow]) -> String {
        guard store.providers != nil else { return "" }
        var parts = [rows.count == 1 ? "1 route" : "\(rows.count) routes"]
        let problems = rows.filter(\.status.isProblem).count
        if problems > 0 { parts.append(problems == 1 ? "1 problem" : "\(problems) problems") }
        return parts.joined(separator: " · ")
    }
}

private struct RoutingToolbar: ToolbarContent {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let loaded: Bool

    var body: some ToolbarContent {
        @Bindable var nav = nav
        let source = nav.selection
        if loaded, case .provider = source {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $nav.tab) {
                    ForEach(SourceTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        if case .failed(let message) = store.saver.status {
            ToolbarItem(placement: .primaryAction) {
                Button("Retry Save", systemImage: "exclamationmark.triangle.fill") { store.scheduleSave() }
                    .tint(.red)
                    .help("Couldn't save routing: \(message)")
            }
        }
        let models = nav.tab == .models || isChannel(source)
        if loaded, models {
            ToolbarItem(placement: .primaryAction) {
                FillButton(source: source)
            }
        }
        if loaded {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if models {
                        Button("Add Models from Catalog…") { nav.catalog = source }
                        Button("Add Blank Row") { addBlank(source) }
                        Divider()
                    }
                    Button("Add API Provider") {
                        let id = store.addProvider()
                        nav.open(.provider(id), tab: .connection)
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    SourceMenu(source: source)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More")
            }
        }
    }

    private func isChannel(_ source: RouteSource) -> Bool {
        if case .channel = source { return true }
        return false
    }

    private func addBlank(_ source: RouteSource) {
        store.addBlankModel(source)
        let count = store.entry(source)?.models.count ?? 0
        nav.models = count > 0 ? [count - 1] : []
    }
}

private struct SourceMenu: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @Environment(AppModel.self) private var app
    let source: RouteSource

    var body: some View {
        Toggle("Enabled", isOn: Binding(
            get: { store.entry(source)?.disabled != true },
            set: { store.setEnabled(source, $0) }))
        Divider()
        switch source {
        case .channel:
            Button("Manage Accounts…") { app.page = .accounts }
        case .provider(let id):
            let upstreams = store.upstreams
            let position = upstreams.firstIndex { $0.id == id } ?? 0
            Button("Edit Connection…") { nav.open(source, tab: .connection) }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let copy = store.duplicate(id) { nav.open(.provider(copy), tab: .connection) }
            }
            Divider()
            Button("Move Up") { store.moveUpstream(id, by: -1) }
                .disabled(position == 0)
            Button("Move Down") { store.moveUpstream(id, by: 1) }
                .disabled(position >= upstreams.count - 1)
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) { nav.removing = id }
        }
    }
}

private struct SourceList: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let rows: [RouteRow]

    var body: some View {
        let upstreams = store.upstreams
        List(selection: selection) {
            Section("Channels") {
                ForEach(ChannelSpec.all) { spec in
                    SourceRow(title: spec.title, count: rows.filter { $0.kind == spec.kind }.count,
                              dimmed: store.entry(.channel(spec.kind))?.disabled == true)
                        .tag(RouteSource.channel(spec.kind))
                        .contextMenu { SourceMenu(source: .channel(spec.kind)) }
                }
            }

            Section("API Providers") {
                ForEach(upstreams, id: \.id) { item in
                    let base = (item.entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
                    SourceRow(title: RoutingTable.sourceName(item.entry), count: item.entry.models.count,
                              dimmed: item.entry.disabled == true)
                        .help(URL(string: base)?.host() ?? base)
                        .tag(RouteSource.provider(item.id))
                        .contextMenu { SourceMenu(source: .provider(item.id)) }
                }
                .onMove { store.moveUpstreams(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            if case .provider(let id) = nav.selection { nav.removing = id }
        }
    }

    private var selection: Binding<RouteSource?> {
        Binding(get: { nav.selection }, set: { value in
            guard let value, value != nav.selection else { return }
            nav.selection = value
            nav.models = []
            if case .provider(let id) = value, let index = store.index(of: .provider(id)),
               RoutingTable.issues(at: index, in: store.list).contains(where: \.blocking) {
                nav.tab = .connection
            } else {
                nav.tab = .models
            }
        })
    }
}

private struct SourceRow: View {
    let title: String
    let count: Int
    var dimmed = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(dimmed ? 0.45 : 1)
            Spacer(minLength: Space.xs)
            Text("\(count)")
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct RoutingDetail: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared

    var body: some View {
        SourceDetail(source: nav.selection)
            .id(nav.selection)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message = store.error {
                    Notice(message: message).padding(Space.md)
                }
            }
    }
}
