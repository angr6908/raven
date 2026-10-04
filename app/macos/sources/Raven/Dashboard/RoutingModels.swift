import AppKit
import SwiftUI

struct ModelLine: Identifiable {
    var id: Int
    var model: ProviderModelDef
    var status: RouteStatus
}

@Observable
final class ModelFiller {
    static let shared = ModelFiller()

    private(set) var done = 0
    private(set) var total = 0
    private(set) var note: String?
    private var task: Task<Void, Never>?

    var running: Bool { task != nil }

    func fill(_ source: RouteSource, rows: [Int]) {
        guard task == nil else { return }
        let store = ProvidersPanelStore.shared
        let models = store.entry(source)?.models ?? []
        let targets = rows.sorted().compactMap { row -> (Int, String)? in
            guard row < models.count else { return nil }
            let name = models[row].name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (row, models[row].name)
        }
        guard !targets.isEmpty else { return }
        let wantsEfforts = source != .channel("antigravity")
        let known = store.effortLevels
        done = 0
        total = targets.count
        note = nil
        task = Task { [weak self] in
            var failure: String?
            for (row, name) in targets {
                guard !Task.isCancelled else { break }
                do {
                    let lookup = try await store.fetchModelsDev(model: name)
                    let efforts = wantsEfforts ? lookup.efforts : []
                    if lookup.context != nil || !efforts.isEmpty {
                        store.updateModel(source, at: row) { model in
                            guard model.name == name else { return }
                            if !efforts.isEmpty {
                                let custom = (model.thinking?.levels ?? []).filter { !known.contains($0) && !efforts.contains($0) }
                                model = PanelLogic.withLevels(model, next: efforts + custom)
                            }
                            if let window = lookup.context { model = PanelLogic.withContext(model, tokens: window) }
                        }
                    }
                } catch PanelError.api(code: "model_not_found", _) {
                } catch {
                    failure = (error as? PanelError)?.noticeText ?? error.localizedDescription
                }
                self?.done += 1
            }
            self?.finish(failure: failure)
        }
    }

    private func finish(failure: String?) {
        task = nil
        note = failure
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        note = nil
    }
}

struct FillButton: View {
    private let nav = RoutingNavigation.shared
    private let filler = ModelFiller.shared
    let source: RouteSource

    var body: some View {
        let selected = !nav.models.isEmpty
        if filler.running {
            Button {
                filler.cancel()
            } label: {
                ProgressView(value: Double(filler.done), total: Double(max(filler.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            .help("Stop")
        } else {
            Button(selected ? "Fill Selected from models.dev" : "Fill All from models.dev",
                   systemImage: "arrow.down.to.line") {
                let count = ProvidersPanelStore.shared.entry(source)?.models.count ?? 0
                filler.fill(source, rows: selected ? Array(nav.models) : Array(0..<count))
            }
            .disabled(ProvidersPanelStore.shared.entry(source)?.models.isEmpty ?? true)
            .help(selected ? "Fill Selected from models.dev" : "Fill All from models.dev")
        }
    }
}

struct ModelsEditor: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    private let filler = ModelFiller.shared
    @Environment(AppModel.self) private var app
    let source: RouteSource

    var body: some View {
        @Bindable var nav = nav
        @Bindable var app = app
        let entry = store.entry(source)
        let index = store.index(of: source)
        let all = store.list
        let lines = (entry?.models ?? []).enumerated().map { offset, model in
            ModelLine(id: offset, model: model,
                      status: index.map { RoutingTable.status(provider: $0, model: offset, in: all) } ?? .active)
        }
        let query = app.query
        let visible = lines.filter {
            query.isEmpty || $0.model.name.lowercased().contains(query)
                || ($0.model.alias ?? "").lowercased().contains(query)
        }

        Group {
            if lines.isEmpty {
                EmptyState(symbol: "square.stack.3d.up.slash", title: "No Models") {
                    Button("Add from Catalog…") { nav.catalog = source }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Table(visible, selection: $nav.models) {
                    TableColumn("") { line in
                        if line.status.isProblem {
                            Image(systemName: line.status.symbol)
                                .foregroundStyle(line.status.tint)
                                .help("\(line.status.title). \(line.status.explanation)")
                        }
                    }
                    .width(16)
                    TableColumn("Upstream Model") { line in
                        HStack(spacing: Space.sm) {
                            ModelLogo(id: line.model.name)
                            InlineField(prompt: "upstream-model-id", text: Binding(
                                get: { line.model.name },
                                set: { text in store.updateModel(source, at: line.id) { $0.name = text } }))
                        }
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Alias") { line in
                        Text(line.model.alias ?? "")
                            .font(.identifier)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .width(min: 120, ideal: 190)
                    TableColumn("Context") { line in
                        ContextCell(value: line.model.maxContextLength) { tokens in
                            store.updateModel(source, at: line.id) { $0 = PanelLogic.withContext($0, tokens: tokens) }
                        }
                    }
                    .width(min: 52, ideal: 60)
                    TableColumn("Reasoning") { line in
                        EffortCell(source: source, line: line)
                    }
                    .width(min: 80, ideal: 100)
                }
                .contextMenu(forSelectionType: Int.self) { rows in
                    menu(rows, lines: lines)
                }
                .onDeleteCommand { remove(nav.models) }
                .overlay {
                    if visible.isEmpty { ContentUnavailableView.search(text: app.search) }
                }
                .searchable(text: $app.search, placement: .toolbar, prompt: "Filter models")
            }
        }
    }

    @ViewBuilder
    private func menu(_ rows: Set<Int>, lines: [ModelLine]) -> some View {
        let picked = lines.filter { rows.contains($0.id) }
        if !picked.isEmpty {
            Button(picked.count == 1 ? "Fill from models.dev" : "Fill \(picked.count) from models.dev") {
                filler.fill(source, rows: picked.map(\.id))
            }
            .disabled(filler.running)
            if picked.count == 1, let line = picked.first {
                Divider()
                Button("Copy Model ID", systemImage: "document.on.document") {
                    app.copy(RoutingTable.clientID(line.model))
                }
                Button("Copy Upstream Name", systemImage: "document.on.document") { app.copy(line.model.name) }
            }
            Divider()
            Button(picked.count == 1 ? "Remove" : "Remove \(picked.count) Models", systemImage: "trash", role: .destructive) {
                remove(Set(picked.map(\.id)))
            }
        }
    }

    private func remove(_ rows: Set<Int>) {
        guard !rows.isEmpty else { return }
        nav.models = []
        store.removeModels(source, at: IndexSet(rows))
    }

}

private struct ModelLogo: View {
    let id: String

    var body: some View {
        let family = ModelFamily(modelID: id)
        if FamilyLogo.logo(for: family) != nil {
            FamilyGlyph(family: family, size: 20)
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }
}

private struct InlineField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.identifier)
            .lineLimit(1)
    }
}

private struct ContextCell: View {
    let value: Int?
    let commit: (Int?) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Context", text: Binding(
            get: { draft ?? value.map(PanelFormats.formatContextWindow) ?? "" },
            set: { draft = $0 }), prompt: Text("Default"))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.figure)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .help("Window the client compacts against, e.g. 200k or 1m. It never caps what Raven forwards.")
    }

    private func save() {
        guard let text = draft else { return }
        draft = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if value != nil { commit(nil) }
        } else if let tokens = PanelFormats.parseTokenCount(trimmed) {
            if tokens != value { commit(tokens) }
        } else {
            NSSound.beep()
        }
    }
}

private struct EffortCell: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource
    let line: ModelLine
    @State private var open = false

    var body: some View {
        let order = store.effortLevels
        if source == .channel("antigravity") {
            let preset = store.antigravityLevels[line.model.name]
            Text(preset.map { $0.isEmpty ? "None" : RoutingTable.effortSummary($0, order: order) } ?? "Preset")
                .foregroundStyle(.secondary)
                .help("Antigravity fixes the levels per model. Clients pick one per request.")
        } else {
            let levels = line.model.thinking?.levels ?? []
            Button {
                open = true
            } label: {
                HStack(spacing: 3) {
                    Text(RoutingTable.effortSummary(levels, order: order))
                        .foregroundStyle(levels.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                EffortPicker(source: source, index: line.id)
            }
            .help("Reasoning levels clients may request")
        }
    }
}

private struct EffortPicker: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource
    let index: Int

    var body: some View {
        let model = store.entry(source).flatMap { index < $0.models.count ? $0.models[index] : nil }
        let levels = model?.thinking?.levels ?? []
        let order = store.effortLevels
        let custom = levels.filter { !order.contains($0) }
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Reasoning Effort").font(.headline)
            let all = order + custom
            Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.sm) {
                ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(all[start..<min(start + 2, all.count)], id: \.self) { level in
                            Toggle(level, isOn: Binding(get: { levels.contains(level) }, set: { _ in toggle(level) }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                Button("Allow All") {
                    store.updateModel(source, at: index) { $0 = PanelLogic.withLevels($0, next: []) }
                }
                .disabled(levels.isEmpty)
                Spacer()
            }
        }
        .padding(Space.lg)
    }

    private func toggle(_ level: String) {
        let order = store.effortLevels
        store.updateModel(source, at: index) { model in
            var current = model.thinking?.levels ?? []
            if current.contains(level) { current.removeAll { $0 == level } } else { current.append(level) }
            model = PanelLogic.withLevels(model, next: RoutingTable.ordered(current, order: order))
        }
    }
}

nonisolated struct CatalogLine: Identifiable, Sendable {
    var model: UpstreamCatalogModel
    var added: Bool

    var id: String { model.id }
    var name: String { model.displayName ?? "" }
    var context: Int { model.contextLength ?? 0 }
    var levels: [String] { model.thinking?.levels ?? model.efforts ?? [] }
    var levelCount: Int { levels.count }
}

struct CatalogSheet: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @Environment(\.dismiss) private var dismiss
    let source: RouteSource
    @State private var catalog: [UpstreamCatalogModel] = []
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    @State private var sort = [KeyPathComparator(\CatalogLine.id)]

    var body: some View {
        let existing = Set((store.entry(source)?.models ?? []).map { $0.name.lowercased() })
        let lines = catalog.map { CatalogLine(model: $0, added: existing.contains($0.id.lowercased())) }
        let visible = filter(lines).sorted(using: sort)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Text("Add Models to \(title)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.md)
                SearchField(text: $query, prompt: "Filter")
                    .frame(width: 200)
            }
            Group {
                if loading {
                    LoadingState(message: "Fetching catalog…")
                } else if let failure {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Fetch the Catalog", message: failure) {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if catalog.isEmpty {
                    EmptyState(symbol: "tray", title: "Empty Catalog")
                } else {
                    table(visible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: Space.sm) {
                let addable = visible.filter { !$0.added }.map(\.id)
                let everything = !addable.isEmpty && addable.allSatisfy(picked.contains)
                Button(everything ? "Deselect All" : "Select All") {
                    if everything { picked.subtract(addable) } else { picked.formUnion(addable) }
                }
                .disabled(addable.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(picked.count > 1 ? "Add \(picked.count) Models" : "Add Model") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .task { await load() }
    }

    private var title: String {
        switch source {
        case .channel(let kind): ChannelSpec.spec(for: kind)?.title ?? kind
        case .provider: store.entry(source).map(RoutingTable.sourceName) ?? "Provider"
        }
    }

    private func table(_ visible: [CatalogLine]) -> some View {
        Table(visible, sortOrder: $sort) {
            TableColumn("") { line in
                Toggle("Add \(line.id)", isOn: Binding(
                    get: { line.added || picked.contains(line.id) },
                    set: { on in
                        if on { picked.insert(line.id) } else { picked.remove(line.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(line.added)
            }
            .width(20)
            TableColumn("Model", value: \.id) { line in
                HStack(spacing: Space.sm) {
                    ModelLogo(id: line.id)
                    Text(line.id)
                        .font(.identifier)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(line.added ? .secondary : .primary)
                }
                .help(line.id)
            }
            .width(min: 200, ideal: 280)
            TableColumn("Name", value: \.name) { line in
                Text(line.name.isEmpty ? "—" : line.name)
                    .foregroundStyle(line.name.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Context", value: \.context) { line in
                Text(line.context > 0 ? PanelFormats.formatContextWindow(line.context) : "—")
                    .font(.figure)
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 68)
            TableColumn("Reasoning", value: \.levelCount) { line in
                Text(line.levels.isEmpty ? "—" : RoutingTable.effortSummary(line.levels, order: store.effortLevels))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .overlay {
            if visible.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func filter(_ lines: [CatalogLine]) -> [CatalogLine] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return lines }
        return lines.filter { $0.id.lowercased().contains(term) || $0.name.lowercased().contains(term) }
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            catalog = try await store.catalog(for: source)
        } catch {
            failure = (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
        loading = false
    }

    private func add() {
        let before = store.entry(source)?.models.count ?? 0
        store.addModels(source, catalog.filter { picked.contains($0.id) })
        let after = store.entry(source)?.models.count ?? 0
        nav.models = Set(before..<after)
        dismiss()
    }
}
