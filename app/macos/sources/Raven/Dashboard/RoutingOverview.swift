import SwiftUI

nonisolated extension RouteRow {
    var priority: Int { provider * 100_000 + model }
}

struct RoutesOverview: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, problems

        var id: String { rawValue }
        var title: String { self == .all ? "All" : "Problems" }
    }

    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @Environment(AppModel.self) private var app
    @AppStorage("routing.scope") private var scope = Scope.all
    @State private var sort: [KeyPathComparator<RouteRow>] = []
    @State private var selection: Set<String> = []
    let rows: [RouteRow]

    var body: some View {
        let visible = filtered
        VStack(spacing: 0) {
            RouteResolver()
                .padding(Space.lg)
            Divider()
            if rows.isEmpty {
                EmptyState(symbol: "arrow.triangle.branch", title: "No Routes Yet",
                           message: "Pin models on a channel or an API provider. Clients then reach each one by its alias or upstream name.") {
                    Button("Add Provider") {
                        let id = store.addProvider()
                        nav.open(.provider(id), tab: .connection)
                    }
                }
            } else {
                table(visible)
            }
        }
    }

    private var filtered: [RouteRow] {
        let query = app.query
        return rows
            .filter { scope == .all || $0.status.isProblem }
            .filter {
                query.isEmpty || $0.clientID.lowercased().contains(query) || $0.upstream.lowercased().contains(query)
                    || $0.source.lowercased().contains(query)
            }
            .sorted(using: sort)
    }

    private func table(_ visible: [RouteRow]) -> some View {
        Table(visible, selection: $selection, sortOrder: $sort) {
            TableColumn("Model ID", value: \.clientID) { row in
                HStack(spacing: Space.sm) {
                    FamilyGlyph(family: ModelFamily(modelID: row.upstream.isEmpty ? row.clientID : row.upstream), size: 20)
                    Text(row.clientID.isEmpty ? "—" : row.clientID)
                        .font(.identifier)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.clientID)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Status", value: \.statusRank) { row in
                Label {
                    Text(row.status.label)
                        .foregroundStyle(row.status == .active ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.status.tint))
                } icon: {
                    Image(systemName: row.status.symbol).foregroundStyle(row.status.tint)
                }
                .lineLimit(1)
                    .help("\(row.status.title). \(row.status.explanation)")
            }
            .width(min: 76, ideal: 92)
            TableColumn("Provider", value: \.priority) { row in
                HStack(spacing: Space.xs) {
                    StatusDot(tint: tint(row))
                    Text(row.source).lineLimit(1)
                }
            }
            .width(min: 76, ideal: 96)
            TableColumn("Upstream", value: \.upstream) { row in
                Text(row.upstream.isEmpty ? "—" : row.upstream)
                    .font(.identifier)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.upstream)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Context", value: \.contextSort) { row in
                Text(row.context.map(PanelFormats.formatContextWindow) ?? "Default")
                    .font(.figure)
                    .foregroundStyle(row.context == nil ? .tertiary : .secondary)
            }
            .width(min: 52, ideal: 56)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                Button("Show in \(row.source)", systemImage: "arrow.right.circle") { reveal(row) }
                Divider()
                Button("Copy Model ID", systemImage: "document.on.document") { app.copy(row.clientID) }
                    .disabled(row.clientID.isEmpty)
                Button("Copy Upstream Name", systemImage: "document.on.document") { app.copy(row.upstream) }
                    .disabled(row.upstream.isEmpty)
            }
        } primaryAction: { ids in
            if let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) { reveal(row) }
        }
        .overlay {
            if visible.isEmpty {
                if app.isSearching {
                    ContentUnavailableView.search(text: app.search)
                } else {
                    ContentUnavailableView("No Problems", systemImage: "checkmark.circle",
                                           description: Text("Every route resolves to its own row."))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: Space.md)
                Text("Double-click a route to edit it")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(.bar)
        }
    }

    private func tint(_ row: RouteRow) -> Color {
        if let spec = ChannelSpec.spec(for: row.kind) { return spec.tint }
        return RouteTint.color(store.list.indices.contains(row.provider) ? store.list[row.provider].name : row.source)
    }

    private func reveal(_ row: RouteRow) {
        guard let source = store.source(at: row.provider) else { return }
        nav.show(source, model: row.model)
    }
}

private struct RouteResolver: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @AppStorage("routing.probe") private var probe = ""

    var body: some View {
        let trimmed = probe.trimmingCharacters(in: .whitespaces)
        let match = trimmed.isEmpty ? nil : RoutingTable.resolve(trimmed, in: store.list, levels: store.effortLevels)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
                    .foregroundStyle(.secondary)
                TextField("Resolve", text: $probe, prompt: Text(verbatim: "Type a model ID a client would send, e.g. glm-4.6@openrouter@high"))
                    .textFieldStyle(.plain)
                    .font(.identifier)
                    .labelsHidden()
                if !probe.isEmpty {
                    Button {
                        probe = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear")
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .glassEffect(.regular, in: .capsule)
            Group {
                if trimmed.isEmpty {
                    Text("Raven matches the alias or upstream name, top provider first. A trailing @effort picks the reasoning level.")
                        .foregroundStyle(.secondary)
                } else if let match {
                    MatchLine(match: match) {
                        if let source = store.source(at: match.provider) { nav.show(source, model: match.model) }
                    }
                } else {
                    Label("No route. Raven has nowhere to send \(trimmed).", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .padding(.horizontal, Space.md)
            .frame(minHeight: 22, alignment: .leading)
        }
    }
}

private struct MatchLine: View {
    let match: RouteMatch
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.good)
            Text("Routes to")
            Text(match.source).fontWeight(.semibold)
            Text("as")
            Text(match.upstream)
                .font(.identifierSmall)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 5))
                .textSelection(.enabled)
            if let effort = match.effort {
                Badge(text: "effort \(effort)", tint: .accentColor, symbol: "brain")
            }
            if match.hidden {
                Badge(text: "hidden from /v1/models", tint: .secondary, symbol: "eye.slash")
            }
            Spacer(minLength: Space.sm)
            Button("Show", action: reveal)
                .buttonStyle(.link)
        }
        .lineLimit(1)
    }
}
