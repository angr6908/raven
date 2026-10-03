import SwiftUI

@Observable
final class ModelZoneState {
    var upstream: [UpstreamCatalogModel] = []
    var picked: Set<String> = []
    var filter = ""
    var fetchError: String?
    var fetching = false
    var fetchingRow: Set<Int> = []
    var rowNotes: [Int: String] = [:]

    private var contextText: [Int: String] = [:]
    private var customText: [Int: String] = [:]
    private var contextTasks: [Int: Task<Void, Never>] = [:]
    private var customTasks: [Int: Task<Void, Never>] = [:]

    func reset() {
        for task in contextTasks.values { task.cancel() }
        for task in customTasks.values { task.cancel() }
        contextTasks.removeAll()
        customTasks.removeAll()
        contextText.removeAll()
        customText.removeAll()
        rowNotes.removeAll()
        upstream = []
        picked = []
        filter = ""
        fetchError = nil
        fetchingRow = []
    }

    func contextText(_ index: Int) -> String? { contextText[index] }
    func setContextText(_ index: Int, _ text: String) { contextText[index] = text }
    func customText(_ index: Int) -> String? { customText[index] }
    func setCustomText(_ index: Int, _ text: String) { customText[index] = text }

    func debounceContext(_ index: Int, _ commit: @escaping () -> Void) {
        contextTasks[index]?.cancel()
        contextTasks[index] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    func debounceCustom(_ index: Int, _ commit: @escaping () -> Void) {
        customTasks[index]?.cancel()
        customTasks[index] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit()
        }
    }
}

@MainActor
@Observable
final class ModelsPanelUI {
    static let shared = ModelsPanelUI()

    private(set) var zones: [String: ModelZoneState] = [:]
    private var expanded: Set<String> = []
    private var autoExpanded: Set<String> = []
    var pendingRemoval: Int?

    func zone(_ key: String) -> ModelZoneState? { zones[key] }

    func ensure(_ key: String) {
        if zones[key] == nil { zones[key] = ModelZoneState() }
    }

    func prune(_ keys: Set<String>) {
        for key in zones.keys where !keys.contains(key) {
            zones.removeValue(forKey: key)
        }
    }

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    func setExpanded(_ key: String, _ open: Bool) {
        if open { expanded.insert(key) } else { expanded.remove(key) }
    }

    func autoExpandOnce(_ key: String) -> Bool {
        guard !expanded.contains(key), !autoExpanded.contains(key) else { return false }
        autoExpanded.insert(key)
        expanded.insert(key)
        return true
    }
}

struct ModelZoneView: View {
    var zoneKey: String
    var entryProvider: () -> ProviderEntry?
    var aliasOwner: () -> String
    var emptyHint: String
    var fetchUpstream: (() async throws -> [UpstreamCatalogModel])?
    var presetEfforts: ((String) -> [String])?
    var onChange: (@escaping (ProviderEntry) -> ProviderEntry) -> Void

    private let store = ProvidersPanelStore.shared
    private var ui: ModelsPanelUI { ModelsPanelUI.shared }

    var body: some View {
        if let state = ui.zone(zoneKey) {
            content(state)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var entry: ProviderEntry? { entryProvider() }
    private var models: [ProviderModelDef] { entry?.models ?? [] }
    private var owner: String { aliasOwner().trimmingCharacters(in: .whitespaces) }

    private var smartAlias: Bool {
        !models.isEmpty && models.allSatisfy {
            $0.name.isEmpty || $0.alias == PanelLogic.smartAliasFor(modelName: $0.name, providerName: owner)
        }
    }

    private func content(_ state: ModelZoneState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            if let fetchError = state.fetchError {
                Text(fetchError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !state.upstream.isEmpty {
                picker(state)
            }
            if models.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    row(state, index: index, model: model)
                }
            }
        }
    }

    private func header(_ state: ModelZoneState) -> some View {
        HStack(spacing: 12) {
            Text("Models (name → alias · context window · effort levels)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Toggle("Smart alias", isOn: Binding(get: { smartAlias }, set: { setSmartAlias($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .disabled(models.isEmpty || owner.isEmpty)
                    .help("Alias = model name without vendor prefix, plus @provider")
                if fetchUpstream != nil {
                    Button(state.fetching ? "Fetching…" : "Fetch models") { runFetch(state) }
                        .controlSize(.small)
                        .disabled(state.fetching)
                }
                Button("Add model", systemImage: "plus") { addModel() }
                    .controlSize(.small)
            }
        }
    }

    private func picker(_ state: ModelZoneState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter \(state.upstream.count) models…", text: Binding(
                    get: { state.filter },
                    set: { state.filter = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(RavenFont.mono(11))
                .frame(width: 190)
                Spacer(minLength: 8)
                Text("\(state.picked.count) selected")
                    .font(RavenFont.mono(11))
                    .foregroundStyle(.secondary)
                Button(state.picked.isEmpty ? "Add selected" : "Add \(state.picked.count) selected",
                       systemImage: "plus") { addSelected(state) }
                    .controlSize(.small)
                    .disabled(state.picked.isEmpty)
                Button {
                    state.reset()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close the picker")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 16, alignment: .leading)],
                          alignment: .leading, spacing: 3) {
                    ForEach(pickerItems(state)) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { state.picked.contains(item.id) },
                            set: { on in
                                if on { state.picked.insert(item.id) } else { state.picked.remove(item.id) }
                            }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(RavenFont.mono(11))
                        .lineLimit(1)
                        .disabled(item.routed)
                        .help(item.routed ? "Already added to this zone" : item.help)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1) }
    }

    private struct PickerItem: Identifiable {
        var id: String
        var title: String
        var routed: Bool
        var help: String
    }

    private func pickerItems(_ state: ModelZoneState) -> [PickerItem] {
        let term = state.filter.trimmingCharacters(in: .whitespaces).lowercased()
        let existing = Set(models.map { $0.name.lowercased() })
        return state.upstream.filter { model in
            term.isEmpty
                || model.id.lowercased().contains(term)
                || (model.displayName ?? "").lowercased().contains(term)
        }.map { model in
            let routed = existing.contains(model.id.lowercased())
            let name = model.displayName ?? ""
            return PickerItem(id: model.id,
                              title: name.isEmpty ? model.id : name,
                              routed: routed,
                              help: name.isEmpty || name == model.id ? model.id : "\(name) (\(model.id))")
        }
    }

    private func row(_ state: ModelZoneState, index: Int, model: ProviderModelDef) -> some View {
        let smartForName = PanelLogic.smartAliasFor(modelName: model.name, providerName: owner)
        let aliasLocked = smartAlias && smartForName == model.alias
        let busy = state.fetchingRow.contains(index)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("upstream-model-name", text: Binding(
                    get: { model.name },
                    set: { commit(index: index, role: "name", text: $0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(RavenFont.mono(11))

                Text("→").font(.system(size: 11)).foregroundStyle(.secondary)

                TextField("alias (optional)", text: Binding(
                    get: { aliasLocked ? smartForName : (model.alias ?? "") },
                    set: { commit(index: index, role: "alias", text: $0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(RavenFont.mono(11))
                .disabled(aliasLocked)
                .help(aliasLocked ? "Managed by Smart alias — toggle it off to edit" : "")

                Spacer(minLength: 8)

                Button(busy ? "…" : "Fetch") { fetchRow(state, index) }
                    .controlSize(.small)
                    .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .help(presetEfforts == nil
                          ? "Fetch context window and effort levels for \(model.name.isEmpty ? "model" : model.name) from models.dev"
                          : "Fetch context window for \(model.name.isEmpty ? "model" : model.name) from models.dev")

                Button {
                    removeRow(index)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Remove this model")
            }

            contextLine(state, index: index, model: model)
            effortLine(state, index: index, model: model)

            if let note = state.rowNotes[index] {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1) }
    }

    private func contextLine(_ state: ModelZoneState, index: Int, model: ProviderModelDef) -> some View {
        HStack(spacing: 8) {
            Text("Context window:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("The window the client compacts against — never a cap on what raven forwards")
            TextField("e.g. 200k", text: Binding(
                get: { state.contextText(index) ?? model.maxContextLength.map(PanelFormats.formatContextWindow) ?? "" },
                set: { text in
                    state.setContextText(index, text)
                    state.debounceContext(index) { commit(index: index, role: "context", text: text) }
                }))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(RavenFont.mono(11))
            .frame(width: 120)
            Text(model.maxContextLength.map(PanelFormats.formatContextWindow)
                 ?? "unset — the client keeps the launcher's default auto-compact window")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func effortLine(_ state: ModelZoneState, index: Int, model: ProviderModelDef) -> some View {
        let levels = model.thinking?.levels ?? []
        if let presetEfforts {
            HStack(spacing: 6) {
                Text("Effort:").font(.system(size: 11)).foregroundStyle(.secondary)
                let preset = presetEfforts(model.name)
                if preset.isEmpty {
                    Text("—").font(RavenFont.mono(11)).foregroundStyle(.secondary)
                } else {
                    ForEach(preset, id: \.self) { level in
                        Text(level)
                            .font(RavenFont.mono(11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1) }
                            .help("Preconfigured — pick the effort per request in your client")
                    }
                }
                Text(preset.isEmpty ? "no reasoning control for this model"
                     : "· set per request by the client (reasoning_effort / thinking)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Text("Effort:").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(store.effortLevels, id: \.self) { level in
                    let on = levels.contains(level)
                    Button(level) { toggleLevel(index: index, level: level) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(RavenFont.mono(10))
                        .tint(on ? .accentColor : nil)
                }
                let custom = levels.filter { !store.effortLevels.contains($0) }
                if !custom.isEmpty {
                    TextField("custom…", text: Binding(
                        get: { state.customText(index) ?? custom.joined(separator: ",") },
                        set: { text in
                            state.setCustomText(index, text)
                            state.debounceCustom(index) { commit(index: index, role: "custom", text: text) }
                        }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(RavenFont.mono(11))
                    .frame(width: 110)
                }
            }
        }
    }

    private func mutate(_ change: @escaping (ProviderEntry) -> ProviderEntry) {
        onChange(change)
    }

    private func setSmartAlias(_ on: Bool) {
        let owner = self.owner
        mutate { provider in
            var entry = provider
            if on {
                entry.models = provider.models.map { model in
                    var updated = model
                    updated.alias = PanelLogic.smartAliasFor(modelName: model.name, providerName: owner)
                    return updated
                }
            } else {
                entry.models = provider.models.map { model in
                    guard model.alias == PanelLogic.smartAliasFor(modelName: model.name, providerName: owner) else { return model }
                    var updated = model
                    updated.alias = nil
                    return updated
                }
            }
            return entry
        }
    }

    private func addModel() {
        mutate { provider in
            var next = provider
            next.models = provider.models + [ProviderModelDef(name: "")]
            return PanelLogic.smartDefault(old: provider, next: next)
        }
    }

    private func removeRow(_ index: Int) {
        mutate { provider in
            var entry = provider
            entry.models = provider.models.enumerated().filter { $0.offset != index }.map(\.element)
            return entry
        }
    }

    private func toggleLevel(index: Int, level: String) {
        mutate { provider in
            var entry = provider
            guard index < entry.models.count else { return entry }
            var model = entry.models[index]
            let current = model.thinking?.levels ?? []
            let next = current.contains(level) ? current.filter { $0 != level } : current + [level]
            model = PanelLogic.withLevels(model, next: next)
            entry.models[index] = model
            return PanelLogic.smartDefault(old: provider, next: entry)
        }
    }

    private func commit(index: Int, role: String, text: String) {
        let knownLevels = store.effortLevels
        mutate { provider in
            var entry = provider
            guard index < entry.models.count else { return provider }
            var model = entry.models[index]
            switch role {
            case "name":
                model.name = text
            case "alias":
                model.alias = text.isEmpty ? nil : text
            case "context":
                model = PanelLogic.withContext(model, tokens: PanelLogic.parseTokenCount(text))
            case "custom":
                let selected = (model.thinking?.levels ?? []).filter { knownLevels.contains($0) }
                let custom = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                model = PanelLogic.withLevels(model, next: selected + custom)
            default:
                return provider
            }
            entry.models[index] = model
            return PanelLogic.smartDefault(old: provider, next: entry)
        }
    }

    private func addSelected(_ state: ModelZoneState) {
        let existing = Set(models.map { $0.name.lowercased() })
        let fresh = state.upstream.filter { state.picked.contains($0.id) && !existing.contains($0.id.lowercased()) }
        guard !fresh.isEmpty else { return }
        mutate { provider in
            var next = provider
            next.models = provider.models + fresh.map { model in
                var def = ProviderModelDef(name: model.id)
                if let context = model.contextLength, context > 0 {
                    def.maxContextLength = context
                }
                return def
            }
            return PanelLogic.smartDefault(old: provider, next: next)
        }
        state.upstream.removeAll { fresh.contains($0) }
        state.picked = []
    }

    private func runFetch(_ state: ModelZoneState) {
        guard let fetchUpstream else { return }
        state.fetching = true
        state.fetchError = nil
        Task {
            do {
                let list = try await fetchUpstream()
                state.upstream = list
                state.picked = []
                state.filter = ""
                state.fetchError = list.isEmpty ? "Upstream returned no models." : nil
            } catch {
                state.fetchError = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            state.fetching = false
        }
    }

    private func fetchRow(_ state: ModelZoneState, _ index: Int) {
        guard let provider = entry, index < provider.models.count else { return }
        let name = provider.models[index].name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let wantsEfforts = presetEfforts == nil
        let knownLevels = store.effortLevels
        let customLevels = (provider.models[index].thinking?.levels ?? [])
            .filter { !knownLevels.contains($0) }
        state.rowNotes[index] = nil
        state.fetchingRow.insert(index)
        Task {
            do {
                let lookup = try await store.fetchModelsDev(model: name)
                let fetchedContext = lookup.context
                let fetchedEfforts = wantsEfforts ? lookup.efforts : []
                if fetchedContext == nil && fetchedEfforts.isEmpty {
                    state.rowNotes[index] = "models.dev (\(lookup.source ?? "?")) lists no context window"
                        + (wantsEfforts ? " or effort levels" : "") + " for this model."
                } else {
                    mutate { provider in
                        var entry = provider
                        guard index < entry.models.count else { return entry }
                        var updated = entry.models[index]
                        if !fetchedEfforts.isEmpty {
                            updated = PanelLogic.withLevels(updated,
                                                            next: fetchedEfforts
                                                                + customLevels.filter { !fetchedEfforts.contains($0) })
                        }
                        if let fetchedContext {
                            updated = PanelLogic.withContext(updated, tokens: fetchedContext)
                        }
                        entry.models[index] = updated
                        return PanelLogic.smartDefault(old: provider, next: entry)
                    }
                    var got: [String] = []
                    if let fetchedContext { got.append("context \(PanelFormats.formatContextWindow(fetchedContext))") }
                    if !fetchedEfforts.isEmpty { got.append("effort levels") }
                    state.rowNotes[index] = "\(got.joined(separator: " + ")) from models.dev (\(lookup.source ?? "?"))"
                }
            } catch {
                let message = (error as? PanelError)?.noticeText ?? error.localizedDescription
                state.rowNotes[index] = PanelLogic.friendlyLookupError(message, what: "context window")
            }
            state.fetchingRow.remove(index)
        }
    }
}
