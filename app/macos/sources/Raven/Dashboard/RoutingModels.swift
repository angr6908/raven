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

    private(set) var source: RouteSource?
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
        self.source = source
        done = 0
        total = targets.count
        note = nil
        task = Task { [weak self] in
            var filled = 0
            var missing: [String] = []
            var failure: String?
            for (row, name) in targets {
                guard !Task.isCancelled else { break }
                do {
                    let lookup = try await store.fetchModelsDev(model: name)
                    let efforts = wantsEfforts ? lookup.efforts : []
                    if lookup.context == nil && efforts.isEmpty {
                        missing.append(name)
                    } else {
                        store.updateModel(source, at: row) { model in
                            guard model.name == name else { return }
                            if !efforts.isEmpty {
                                let custom = (model.thinking?.levels ?? []).filter { !known.contains($0) && !efforts.contains($0) }
                                model = PanelLogic.withLevels(model, next: efforts + custom)
                            }
                            if let window = lookup.context { model = PanelLogic.withContext(model, tokens: window) }
                        }
                        filled += 1
                    }
                } catch PanelError.api(code: "model_not_found", _) {
                    missing.append(name)
                } catch {
                    failure = (error as? PanelError)?.noticeText ?? error.localizedDescription
                }
                self?.done += 1
            }
            self?.finish(filled: filled, missing: missing, failure: failure)
        }
    }

    private func finish(filled: Int, missing: [String], failure: String?) {
        task = nil
        var parts: [String] = []
        if filled > 0 { parts.append(filled == 1 ? "Filled 1 model from models.dev." : "Filled \(filled) models from models.dev.") }
        if !missing.isEmpty {
            let names = missing.prefix(3).joined(separator: ", ") + (missing.count > 3 ? " and \(missing.count - 3) more" : "")
            parts.append("models.dev has nothing for \(names).")
        }
        if let failure { parts.append(failure) }
        note = parts.isEmpty ? "Stopped." : parts.joined(separator: " ")
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        note = nil
        source = nil
    }
}

struct FillButton: View {
    private let nav = RoutingNavigation.shared
    private let filler = ModelFiller.shared
    let source: RouteSource

    var body: some View {
        let selected = !nav.models.isEmpty
        Button(selected ? "Fill Selected from models.dev" : "Fill All from models.dev",
               systemImage: "arrow.down.to.line") {
            let count = ProvidersPanelStore.shared.entry(source)?.models.count ?? 0
            filler.fill(source, rows: selected ? Array(nav.models) : Array(0..<count))
        }
        .disabled(filler.running || (ProvidersPanelStore.shared.entry(source)?.models.isEmpty ?? true))
        .help(selected ? "Look up context windows and effort levels for the selected models on models.dev"
              : "Look up context windows and effort levels for every model on models.dev")
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
        let smart = store.smartAliasOn(source)
        let owner = store.owner(source)
        let blocking = index.map { RoutingTable.issues(at: $0, in: all).filter(\.blocking) } ?? []

        VStack(spacing: 0) {
            if let issue = blocking.first {
                HStack(spacing: Space.md) {
                    Notice(message: "This provider can't route yet. \(issue.message)", severity: .warning)
                    Button("Fix") { nav.tab = .connection }
                }
                .padding(Space.md)
            }
            if lines.isEmpty {
                EmptyState(symbol: "square.stack.3d.up.slash", title: "No Models",
                           message: "Clients reach only the models listed here, by alias or upstream name.") {
                    HStack {
                        Button("Add from Catalog…") { nav.catalog = source }
                            .buttonStyle(.glassProminent)
                        Button("Add Blank Row") { addBlank() }
                            .buttonStyle(.glass)
                    }
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
                            FamilyGlyph(family: ModelFamily(modelID: line.model.name), size: 20)
                            InlineField(prompt: "upstream-model-id", text: Binding(
                                get: { line.model.name },
                                set: { text in store.updateModel(source, at: line.id, smart: true) { $0.name = text } }))
                        }
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Alias") { line in
                        AliasCell(line: line, smart: smart, owner: owner) { text in
                            store.updateModel(source, at: line.id) { $0.alias = text }
                        }
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if filler.source == source, filler.running || filler.note != nil {
                FillStatus()
                    .padding(Space.md)
            }
        }
    }

    @ViewBuilder
    private func menu(_ rows: Set<Int>, lines: [ModelLine]) -> some View {
        let picked = lines.filter { rows.contains($0.id) }
        if !picked.isEmpty {
            Button(picked.count == 1 ? "Fill from models.dev" : "Fill \(picked.count) from models.dev",
                   systemImage: "arrow.down.to.line") {
                filler.fill(source, rows: picked.map(\.id))
            }
            .disabled(filler.running)
            if picked.count == 1, let line = picked.first {
                Divider()
                Button("Copy Model ID", systemImage: "document.on.document") {
                    app.copy(RoutingTable.clientID(line.model))
                }
                Button("Copy Upstream Name", systemImage: "document.on.document") { app.copy(line.model.name) }
                if line.status.isProblem {
                    Divider()
                    Text(line.status.explanation)
                }
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

    private func addBlank() {
        store.addBlankModel(source)
        let count = store.entry(source)?.models.count ?? 0
        nav.models = count > 0 ? [count - 1] : []
    }
}

private struct FillStatus: View {
    private let filler = ModelFiller.shared

    var body: some View {
        HStack(spacing: Space.md) {
            if filler.running {
                ProgressView(value: Double(filler.done), total: Double(max(filler.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Looking up \(min(filler.done + 1, filler.total)) of \(filler.total) on models.dev…")
                Spacer(minLength: Space.md)
                Button("Stop") { filler.cancel() }
            } else if let note = filler.note {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text(note).lineLimit(2)
                Spacer(minLength: Space.md)
                Button {
                    filler.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .font(.callout)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .glassEffect(.regular, in: .capsule)
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

private struct AliasCell: View {
    let line: ModelLine
    let smart: Bool
    let owner: String
    let commit: (String) -> Void

    var body: some View {
        let alias = line.model.alias ?? ""
        if smart, !line.model.name.isEmpty,
           alias == PanelLogic.smartAliasFor(modelName: line.model.name, providerName: owner) {
            HStack(spacing: Space.xs) {
                Image(systemName: "wand.and.sparkles")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                Text(alias)
                    .font(.identifier)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help("Smart alias. It follows the model name; turn Smart Aliases off to set your own.")
        } else {
            InlineField(prompt: line.model.name.isEmpty ? "alias" : line.model.name,
                        text: Binding(get: { alias }, set: { commit($0) }))
                .help(alias.isEmpty ? "No alias: clients use the upstream name" : "Clients send \(alias)")
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Reasoning Effort").font(.headline)
                Text(model?.name.isEmpty == false ? model?.name ?? "" : "Unnamed model")
                    .font(.identifierSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                ForEach(order + custom, id: \.self) { level in
                    let on = levels.contains(level)
                    Toggle(isOn: Binding(get: { on }, set: { _ in toggle(level) })) {
                        HStack(spacing: 3) {
                            if on { Image(systemName: "checkmark").imageScale(.small) }
                            Text(level)
                        }
                        .fontWeight(on ? .semibold : .regular)
                        .frame(maxWidth: .infinity)
                    }
                    .toggleStyle(.button)
                }
            }
            Text(levels.isEmpty ? "None picked, so clients may ask for any level."
                 : "Clients may ask for these levels only, with a trailing @level or reasoning_effort.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow All") {
                    store.updateModel(source, at: index) { $0 = PanelLogic.withLevels($0, next: []) }
                }
                .disabled(levels.isEmpty)
                Spacer()
            }
        }
        .padding(Space.lg)
        .frame(width: 300)
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
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $query, prompt: Text(loading ? "Fetching catalog…" : "Filter \(catalog.count) models"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .glassEffect(.regular, in: .capsule)
                .padding(Space.md)
                Divider()
                Group {
                    if loading {
                        LoadingState(message: "Fetching catalog…")
                    } else if let failure {
                        EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Fetch the Catalog", message: failure) {
                            Button("Try Again") { Task { await load() } }
                        }
                    } else if catalog.isEmpty {
                        EmptyState(symbol: "tray", title: "Empty Catalog", message: "The upstream returned no models.")
                    } else {
                        table(visible)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: Space.md) {
                    let addable = visible.filter { !$0.added }.map(\.id)
                    Button("Select All") { picked.formUnion(addable) }
                        .disabled(addable.isEmpty || addable.allSatisfy(picked.contains))
                    Button("Select None") { picked.removeAll() }
                        .disabled(picked.isEmpty)
                    Spacer()
                    Text(summary(lines))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(Space.md)
            }
            .navigationTitle("Add Models")
            .navigationSubtitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.count > 1 ? "Add \(picked.count) Models" : "Add Model") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked.isEmpty)
                }
            }
        }
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
                    FamilyGlyph(family: ModelFamily(modelID: line.id), size: 20)
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
                Text(line.added ? "Added" : (line.name.isEmpty ? "—" : line.name))
                    .foregroundStyle(line.name.isEmpty && !line.added ? .tertiary : .secondary)
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
        .overlay {
            if visible.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func filter(_ lines: [CatalogLine]) -> [CatalogLine] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return lines }
        return lines.filter { $0.id.lowercased().contains(term) || $0.name.lowercased().contains(term) }
    }

    private func summary(_ lines: [CatalogLine]) -> String {
        let added = lines.filter(\.added).count
        var parts = ["\(picked.count) selected"]
        if added > 0 { parts.append("\(added) already added") }
        return parts.joined(separator: " · ")
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
