import SwiftUI

enum RoutingSelection: Hashable {
    case routes
    case source(RouteSource)
}

enum SourceTab: String, CaseIterable, Identifiable {
    case models, connection

    var id: String { rawValue }
    var title: String { self == .models ? "Models" : "Connection" }
}

@Observable
final class RoutingNavigation {
    static let shared = RoutingNavigation()

    var selection: RoutingSelection = .routes
    var tab: SourceTab = .models
    var models: Set<Int> = []
    var catalog: RouteSource?
    var removing: UUID?

    var source: RouteSource? {
        if case .source(let source) = selection { return source }
        return nil
    }

    func show(_ source: RouteSource, model: Int? = nil) {
        selection = .source(source)
        tab = .models
        models = model.map { [$0] } ?? []
    }

    func open(_ source: RouteSource, tab: SourceTab) {
        selection = .source(source)
        self.tab = tab
        models = []
    }
}

extension ChannelSpec {
    var tint: Color { kind == "antigravity" ? .indigo : .teal }
}

enum RouteTint {
    static func color(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red]
        let seed = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[seed % palette.count]
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
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var nav = nav
        let rows = RoutingTable.rows(store.list)
        Group {
            if store.providers != nil {
                HStack(spacing: 0) {
                    SourceList(rows: rows)
                        .frame(width: 264)
                    Divider()
                    RoutingDetail(rows: rows)
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
        .searchable(text: $app.search, placement: .toolbar, prompt: "Filter models")
        .toolbar { RoutingToolbar() }
        .sheet(item: $nav.catalog) { source in
            CatalogSheet(source: source)
        }
        .confirmationDialog("Remove this provider?", isPresented: Binding(
            get: { nav.removing != nil }, set: { if !$0 { nav.removing = nil } }), presenting: nav.removing) { id in
            Button("Remove \(store.entry(.provider(id)).map(RoutingTable.sourceName) ?? "Provider")", role: .destructive) {
                if nav.selection == .source(.provider(id)) { nav.selection = .routes }
                store.remove(id)
            }
        } message: { id in
            let count = store.entry(.provider(id))?.models.count ?? 0
            Text(count == 0 ? "Its endpoint and API keys leave the routing doc."
                 : "Its endpoint, API keys and \(count == 1 ? "1 model" : "\(count) models") leave the routing doc. Clients asking for those models stop getting answers.")
        }
        .onChange(of: store.ids) {
            if case .source(.provider(let id)) = nav.selection, !store.ids.contains(id) {
                nav.selection = .routes
            }
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

    var body: some ToolbarContent {
        if store.saver.status != .idle {
            ToolbarItem(placement: .primaryAction) {
                SaveIndicator()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if let source = nav.source, nav.tab == .models || isChannel(source) {
            ToolbarItem(placement: .primaryAction) {
                FillButton(source: source)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add from Catalog…", systemImage: "square.grid.2x2") { nav.catalog = source }
                    Button("Add Blank Row", systemImage: "plus.rectangle") { addBlank(source) }
                } label: {
                    Label("Add Models", systemImage: "plus")
                } primaryAction: {
                    nav.catalog = source
                }
                .help("Add models from the upstream catalog, or a blank row from the menu")
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

private struct SaveIndicator: View {
    private let store = ProvidersPanelStore.shared

    var body: some View {
        switch store.saver.status {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Saving…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .help("Changes save automatically and the proxy reloads them")
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help(savedHelp)
        case .failed(let message):
            Button {
                store.scheduleSave()
            } label: {
                Label("Retry Save", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
            }
            .help("Save failed: \(message)")
        }
    }

    private var savedHelp: String {
        guard let date = store.saver.savedAt else { return "Saved to the routing doc" }
        return "Saved to the routing doc at \(date.formatted(date: .omitted, time: .standard))"
    }
}

private struct SourceList: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @Environment(AppModel.self) private var app
    let rows: [RouteRow]

    var body: some View {
        let upstreams = store.upstreams
        List(selection: selection) {
            AllRoutesRow(rows: rows)
                .tag(RoutingSelection.routes)

            Section("Channels") {
                ForEach(ChannelSpec.all) { spec in
                    ChannelRow(spec: spec, rows: rows.filter { $0.kind == spec.kind })
                        .tag(RoutingSelection.source(.channel(spec.kind)))
                        .contextMenu { channelMenu(spec) }
                }
            }

            Section {
                ForEach(Array(upstreams.enumerated()), id: \.element.id) { position, item in
                    UpstreamRow(entry: item.entry, priority: position + 1,
                                issues: RoutingTable.issues(at: item.index, in: store.list),
                                problems: rows.filter { $0.provider == item.index && $0.status.isProblem }.count)
                        .tag(RoutingSelection.source(.provider(item.id)))
                        .contextMenu { upstreamMenu(item.id, entry: item.entry, position: position, count: upstreams.count) }
                }
                .onMove { store.moveUpstreams(from: $0, to: $1) }
            } header: {
                Text("API Providers")
            } footer: {
                if upstreams.count > 1 {
                    Text("Raven tries providers top to bottom. Drag to reorder.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .source(.provider(let id)) = nav.selection { nav.removing = id }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Provider", systemImage: "plus") {
                    let id = store.addProvider()
                    nav.open(.provider(id), tab: .connection)
                }
                .buttonStyle(.glass)
                .help("Add an OpenAI-compatible API provider")
                Spacer(minLength: 0)
            }
            .padding(Space.md)
        }
    }

    private var selection: Binding<RoutingSelection?> {
        Binding(get: { nav.selection }, set: { value in
            guard let value, value != nav.selection else { return }
            nav.selection = value
            nav.models = []
            if case .source(.provider(let id)) = value, let index = store.index(of: .provider(id)),
               RoutingTable.issues(at: index, in: store.list).contains(where: \.blocking) {
                nav.tab = .connection
            } else {
                nav.tab = .models
            }
        })
    }

    @ViewBuilder
    private func channelMenu(_ spec: ChannelSpec) -> some View {
        let enabled = store.entry(.channel(spec.kind))?.disabled != true
        Button(enabled ? "Turn Off" : "Turn On", systemImage: enabled ? "pause.circle" : "play.circle") {
            store.setEnabled(.channel(spec.kind), !enabled)
        }
        Button("Add from Catalog…", systemImage: "square.grid.2x2") {
            nav.show(.channel(spec.kind))
            nav.catalog = .channel(spec.kind)
        }
        Divider()
        Button("Manage Accounts…", systemImage: "person.2.badge.key") { app.page = .accounts }
    }

    @ViewBuilder
    private func upstreamMenu(_ id: UUID, entry: ProviderEntry, position: Int, count: Int) -> some View {
        let enabled = entry.disabled != true
        Button(enabled ? "Turn Off" : "Turn On", systemImage: enabled ? "pause.circle" : "play.circle") {
            store.setEnabled(.provider(id), !enabled)
        }
        Button("Edit Connection…", systemImage: "network") { nav.open(.provider(id), tab: .connection) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            if let copy = store.duplicate(id) { nav.open(.provider(copy), tab: .connection) }
        }
        Divider()
        Button("Move Up", systemImage: "arrow.up") { store.moveUpstream(id, by: -1) }
            .disabled(position == 0)
        Button("Move Down", systemImage: "arrow.down") { store.moveUpstream(id, by: 1) }
            .disabled(position >= count - 1)
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { nav.removing = id }
    }
}

private struct SourceRowLayout<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var mono = false
    var dimmed = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Space.sm) {
            Glyph(symbol: symbol, tint: dimmed ? .secondary : tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(mono ? .identifier : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.xs)
            accessory
        }
        .padding(.vertical, 2)
        .opacity(dimmed ? 0.6 : 1)
    }
}

private struct AllRoutesRow: View {
    let rows: [RouteRow]

    var body: some View {
        let problems = rows.filter(\.status.isProblem).count
        SourceRowLayout(symbol: "arrow.triangle.branch", tint: .accentColor, title: "All Routes",
                        subtitle: summary(problems)) {
            if problems > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(problems == 1 ? "1 route needs attention" : "\(problems) routes need attention")
            }
        }
    }

    private func summary(_ problems: Int) -> String {
        let active = rows.filter { $0.status == .active }.count
        if rows.isEmpty { return "No models yet" }
        return active == rows.count ? "\(rows.count) live" : "\(active) of \(rows.count) live"
    }
}

private struct ChannelRow: View {
    private let store = ProvidersPanelStore.shared
    let spec: ChannelSpec
    let rows: [RouteRow]

    var body: some View {
        let entry = store.entry(.channel(spec.kind))
        let off = entry?.disabled == true
        let problems = rows.filter(\.status.isProblem).count
        SourceRowLayout(symbol: spec.symbol, tint: spec.tint, title: spec.title,
                        subtitle: subtitle(off: off), dimmed: off) {
            if problems > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(problems == 1 ? "1 model needs attention" : "\(problems) models need attention")
            }
        }
    }

    private func subtitle(off: Bool) -> String {
        let count = rows.count == 1 ? "1 model" : "\(rows.count) models"
        return off ? "Off · \(count)" : (rows.isEmpty ? "No models pinned" : count)
    }
}

private struct UpstreamRow: View {
    let entry: ProviderEntry
    let priority: Int
    let issues: [ProviderIssue]
    let problems: Int

    var body: some View {
        let off = entry.disabled == true
        let blocking = issues.filter(\.blocking)
        SourceRowLayout(symbol: "server.rack", tint: RouteTint.color(entry.name),
                        title: RoutingTable.sourceName(entry), subtitle: subtitle(off: off, blocking: !blocking.isEmpty),
                        mono: !entry.name.trimmingCharacters(in: .whitespaces).isEmpty, dimmed: off) {
            if !blocking.isEmpty || problems > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(blocking.first?.message ?? (problems == 1 ? "1 model needs attention" : "\(problems) models need attention"))
            } else {
                Text("\(priority)")
                    .font(.figureSmall)
                    .foregroundStyle(.tertiary)
                    .help("Priority \(priority): earlier providers win when two list the same model")
            }
        }
    }

    private func subtitle(off: Bool, blocking: Bool) -> String {
        let count = entry.models.count == 1 ? "1 model" : "\(entry.models.count) models"
        if blocking { return "Needs setup · \(count)" }
        let host = (entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
        let label = URL(string: host)?.host() ?? host
        let parts = [off ? "Off" : nil, label.isEmpty ? nil : label, count].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

private struct RoutingDetail: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let rows: [RouteRow]

    var body: some View {
        Group {
            switch nav.selection {
            case .routes:
                RoutesOverview(rows: rows)
            case .source(let source):
                SourceDetail(source: source)
                    .id(source)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = failure {
                Notice(message: message).padding(Space.md)
            }
        }
    }

    private var failure: String? {
        if case .failed(let message) = store.saver.status { return "Couldn't save routing: \(message)" }
        return store.error
    }
}
