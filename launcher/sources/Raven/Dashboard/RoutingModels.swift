import SwiftUI

struct ModelsContext {
    var entry: () -> ProviderEntry?
    var aliasOwner: () -> String
    var emptyHint: String
    var fetchUpstream: (() async throws -> [UpstreamCatalogModel])?
    var presetEfforts: ((String) -> [String])?
    var onChange: (@escaping (ProviderEntry) -> ProviderEntry) -> Void

    var models: [ProviderModelDef] { entry()?.models ?? [] }
    var owner: String { aliasOwner().trimmingCharacters(in: .whitespaces) }
    var effortLevels: [String] { ProvidersPanelStore.shared.effortLevels }

    var smartAlias: Bool {
        let owner = owner
        return !models.isEmpty && models.allSatisfy {
            $0.name.isEmpty || $0.alias == PanelLogic.smartAliasFor(modelName: $0.name, providerName: owner)
        }
    }

    func setSmartAlias(_ on: Bool) {
        let owner = owner
        onChange { provider in
            var entry = provider
            entry.models = provider.models.map { model in
                var updated = model
                let smart = PanelLogic.smartAliasFor(modelName: model.name, providerName: owner)
                if on {
                    updated.alias = smart
                } else if model.alias == smart {
                    updated.alias = nil
                }
                return updated
            }
            return entry
        }
    }

    func update(at index: Int, _ change: @escaping (inout ProviderModelDef) -> Void) {
        onChange { provider in
            var entry = provider
            guard index < entry.models.count else { return provider }
            change(&entry.models[index])
            return PanelLogic.smartDefault(old: provider, next: entry)
        }
    }

    func addBlank() {
        onChange { provider in
            var next = provider
            next.models.append(ProviderModelDef(name: ""))
            return PanelLogic.smartDefault(old: provider, next: next)
        }
    }

    func remove(at index: Int) {
        onChange { provider in
            var entry = provider
            guard index < entry.models.count else { return entry }
            entry.models.remove(at: index)
            return entry
        }
    }

    func add(_ upstream: [UpstreamCatalogModel]) {
        onChange { provider in
            var next = provider
            let existing = Set(provider.models.map { $0.name.lowercased() })
            next.models = provider.models + upstream.filter { !existing.contains($0.id.lowercased()) }.map { model in
                var def = ProviderModelDef(name: model.id)
                if let context = model.contextLength, context > 0 { def.maxContextLength = context }
                return def
            }
            return PanelLogic.smartDefault(old: provider, next: next)
        }
    }
}

struct ModelsList: View {
    let context: ModelsContext
    @State private var editing: Int?
    @State private var showingCatalog = false

    var body: some View {
        let models = context.models
        if models.isEmpty {
            Text(context.emptyHint).font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(Array(models.enumerated()), id: \.offset) { index, model in
            Button {
                editing = index
            } label: {
                HStack(spacing: Space.md) {
                    FamilyGlyph(family: ModelFamily(modelID: model.name), size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name.isEmpty ? "Unnamed model" : model.name)
                            .font(.identifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let alias = model.alias, !alias.isEmpty {
                            Text(alias).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.md)
                    if let window = model.maxContextLength {
                        Text(PanelFormats.formatContextWindow(window)).font(.figure).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } }),
                     arrowEdge: .trailing) {
                ModelEditor(context: context, index: index, close: { editing = nil })
            }
            .contextMenu {
                Button("Edit…", systemImage: "pencil") { editing = index }
                Button("Remove", systemImage: "trash", role: .destructive) { context.remove(at: index) }
            }
        }
        HStack(spacing: Space.sm) {
            Button("Add Model", systemImage: "plus") {
                context.addBlank()
                editing = context.models.count - 1
            }
            if context.fetchUpstream != nil {
                Button("Add from Catalog…", systemImage: "square.grid.2x2") { showingCatalog = true }
                    .popover(isPresented: $showingCatalog, arrowEdge: .trailing) {
                        CatalogPicker(context: context, isPresented: $showingCatalog)
                    }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        if !models.isEmpty {
            Toggle(isOn: Binding(get: { context.smartAlias }, set: { context.setSmartAlias($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smart Alias")
                    Text("Name each model without its vendor prefix, plus @\(context.owner.isEmpty ? "provider" : context.owner)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(context.owner.isEmpty)
        }
    }
}

private struct ModelEditor: View {
    let context: ModelsContext
    let index: Int
    let close: () -> Void
    @State private var windowText = ""
    @State private var fetching = false
    @State private var note: String?

    var body: some View {
        let models = context.models
        if index < models.count {
            let model = models[index]
            let smart = context.smartAlias
            Form {
                Section {
                    TextField("Model", text: Binding(
                        get: { model.name }, set: { text in context.update(at: index) { $0.name = text } }),
                        prompt: Text("upstream-model-name"))
                        .font(.identifier)
                    TextField("Alias", text: Binding(
                        get: { model.alias ?? "" },
                        set: { text in context.update(at: index) { $0.alias = text.isEmpty ? nil : text } }),
                        prompt: Text("Optional"))
                        .font(.identifier)
                        .disabled(smart)
                    TextField("Context", text: $windowText, prompt: Text("e.g. 200k"))
                        .font(.identifier)
                        .onSubmit(commitWindow)
                } footer: {
                    Text(smart ? "Smart Alias is on, so the alias follows the model name."
                         : "Context is the window the client compacts against. It never caps what Raven forwards.")
                }

                Section("Reasoning Effort") {
                    EffortRow(context: context, index: index, model: model)
                }

                Section {
                    Button(fetching ? "Fetching…" : "Fill from models.dev", systemImage: "arrow.down.to.line") { fetch(model) }
                        .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || fetching)
                    if let note {
                        Text(note).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("Remove Model", systemImage: "trash", role: .destructive) {
                        close()
                        context.remove(at: index)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380, height: 440)
            .onAppear { windowText = model.maxContextLength.map(PanelFormats.formatContextWindow) ?? "" }
            .onDisappear(perform: commitWindow)
        }
    }

    private func commitWindow() {
        guard index < context.models.count else { return }
        let tokens = PanelFormats.parseTokenCount(windowText)
        guard tokens != context.models[index].maxContextLength else { return }
        context.update(at: index) { $0 = PanelLogic.withContext($0, tokens: tokens) }
    }

    private func fetch(_ model: ProviderModelDef) {
        let name = model.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let wantsEfforts = context.presetEfforts == nil
        let known = context.effortLevels
        fetching = true
        note = nil
        Task {
            defer { fetching = false }
            do {
                let lookup = try await ProvidersPanelStore.shared.fetchModelsDev(model: name)
                let efforts = wantsEfforts ? lookup.efforts : []
                guard lookup.context != nil || !efforts.isEmpty else {
                    note = "models.dev has nothing for this model."
                    return
                }
                let custom = (model.thinking?.levels ?? []).filter { !known.contains($0) }
                context.update(at: index) { updated in
                    if !efforts.isEmpty {
                        updated = PanelLogic.withLevels(updated, next: efforts + custom.filter { !efforts.contains($0) })
                    }
                    if let window = lookup.context { updated = PanelLogic.withContext(updated, tokens: window) }
                }
                if let window = lookup.context { windowText = PanelFormats.formatContextWindow(window) }
            } catch {
                let message = (error as? PanelError)?.noticeText ?? error.localizedDescription
                note = PanelLogic.friendlyLookupError(message, what: "context window")
            }
        }
    }
}

private struct EffortRow: View {
    let context: ModelsContext
    let index: Int
    let model: ProviderModelDef

    var body: some View {
        if let preset = context.presetEfforts {
            let levels = preset(model.name)
            LabeledContent("Levels") {
                Text(levels.isEmpty ? "None" : levels.joined(separator: ", ")).font(.identifier)
            }
        } else {
            let levels = model.thinking?.levels ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Space.sm)], alignment: .leading, spacing: Space.sm) {
                ForEach(context.effortLevels, id: \.self) { level in
                    Toggle(level, isOn: Binding(
                        get: { levels.contains(level) },
                        set: { _ in toggle(level) }))
                        .toggleStyle(.button)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Space.xs)
        }
    }

    private func toggle(_ level: String) {
        let order = context.effortLevels
        context.update(at: index) { model in
            var current = model.thinking?.levels ?? []
            if current.contains(level) { current.removeAll { $0 == level } } else { current.append(level) }
            let known = current.filter { order.contains($0) }.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            let custom = current.filter { !order.contains($0) }
            model = PanelLogic.withLevels(model, next: known + custom)
        }
    }
}

private struct CatalogPicker: View {
    let context: ModelsContext
    @Binding var isPresented: Bool
    @State private var catalog: [UpstreamCatalogModel] = []
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        let existing = Set(context.models.map { $0.name.lowercased() })
        VStack(spacing: 0) {
            TextField("Filter \(catalog.count) models", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(Space.md)
            Divider()
            Group {
                if loading {
                    LoadingState(message: "Fetching catalog…")
                } else if let failure {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Fetch", message: failure) {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    List(filtered, selection: $picked) { model in
                        let added = existing.contains(model.id.lowercased())
                        HStack {
                            Text(model.displayName ?? model.id).font(.identifierSmall).lineLimit(1)
                            Spacer()
                            if added { Text("Added").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .tag(model.id)
                        .selectionDisabled(added)
                    }
                    .listStyle(.plain)
                }
            }
            Divider()
            HStack {
                Text(picked.isEmpty ? "Select models to add" : "\(picked.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    context.add(catalog.filter { picked.contains($0.id) })
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty)
            }
            .padding(Space.md)
        }
        .frame(width: 400, height: 420)
        .task { await load() }
    }

    private var filtered: [UpstreamCatalogModel] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return catalog }
        return catalog.filter { $0.id.lowercased().contains(term) || ($0.displayName ?? "").lowercased().contains(term) }
    }

    private func load() async {
        guard let fetch = context.fetchUpstream else { return }
        loading = true
        failure = nil
        do {
            catalog = try await fetch()
        } catch {
            failure = (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
        loading = false
    }
}
