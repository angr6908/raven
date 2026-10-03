import SwiftUI

struct ProvidersPanelView: View {
    private let store = ProvidersPanelStore.shared
    private var ui: ModelsPanelUI { ModelsPanelUI.shared }

    var body: some View {
        PanelPage {
            PanelPageHeader(title: "Models",
                            subtitle: routingSummary,
                            icon: "square.stack.3d.up.fill")
            PanelNotice(message: store.error)
            saveStatus
            if store.loading || store.providers == nil {
                RavenLoader(message: "Loading providers…").frame(height: 160)
            } else {
                managedZones
                providersSection
            }
        }
        .onAppear {
            syncUI()
            store.start()
        }
        .onChange(of: (store.providers ?? []).count) { _, _ in syncUI() }
        .alert("Remove provider?", isPresented: removalBinding, presenting: ui.pendingRemoval) { index in
            Button("Remove \(name(at: index))", role: .destructive) {
                store.removeProvider(index: index)
                ui.pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { ui.pendingRemoval = nil }
        } message: { _ in
            Text("Its models and API keys are dropped from the routing doc on save.")
        }
    }

    private var routingSummary: String? {
        guard let providers = store.providers else { return nil }
        let pinned = providers.reduce(0) { $0 + $1.models.count }
        let active = providers.filter { $0.disabled != true }.count
        return "\(providers.count) provider\(providers.count == 1 ? "" : "s") · \(active) active · \(pinned) model\(pinned == 1 ? "" : "s") pinned"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { ui.pendingRemoval != nil }, set: { if !$0 { ui.pendingRemoval = nil } })
    }

    private func name(at index: Int) -> String {
        let list = store.providers ?? []
        return index < list.count ? (list[index].name.isEmpty ? "unnamed" : list[index].name) : "unnamed"
    }

    private var saveStatus: some View {
        Group {
            switch store.saver.status {
            case .idle:
                EmptyView()
            case .saving:
                statusRow(color: .yellow, text: "Saving…", tint: .secondary)
            case .saved:
                statusRow(color: .green, text: ProvidersPanelStore.savedNotice, tint: .secondary)
            case .failed(let message):
                statusRow(color: .red, text: "Save failed — \(message)", tint: .red)
            }
        }
    }

    private func statusRow(color: Color, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(tint)
        }
    }

    private func syncUI() {
        var keys: Set<String> = []
        for spec in Self.zoneSpecs { keys.insert(spec.key) }
        for item in endpoints { keys.insert(Self.providerKey(item.index)) }
        for spec in Self.zoneSpecs { ui.ensure(spec.key) }
        for item in endpoints { ui.ensure(Self.providerKey(item.index)) }
        ui.prune(keys)
    }

    struct ZoneSpec {
        var key: String
        var title: String
        var match: (ProviderEntry) -> Bool
        var blank: () -> ProviderEntry
        var aliasOwner: String
        var followEntryName: Bool
        var fetchKind: String
        var presets: Bool
        var emptyHint: String
    }

    static let zoneSpecs: [ZoneSpec] = [
        ZoneSpec(key: "workbuddy", title: "WorkBuddy",
                 match: { $0.kind == "workbuddy" },
                 blank: { PanelLogic.blankProviderEntry(kind: "workbuddy", name: "workbuddy") },
                 aliasOwner: "workbuddy", followEntryName: false, fetchKind: "workbuddy", presets: false,
                 emptyHint: "No models pinned — fetch the upstream catalog and pick, or add a row by hand. Unlisted workbuddy ids still route by name."),
        ZoneSpec(key: "antigravity", title: "Antigravity",
                 match: { $0.kind == "antigravity" },
                 blank: { PanelLogic.blankProviderEntry(kind: "antigravity", name: "antigravity") },
                 aliasOwner: "antigravity", followEntryName: false, fetchKind: "antigravity", presets: true,
                 emptyHint: "No models pinned — fetch the catalog and pick, or add a row by hand. Unlisted antigravity ids still route by name."),
    ]

    static func providerKey(_ index: Int) -> String {
        "p:\(index)"
    }

    private func zoneEntry(_ spec: ZoneSpec) -> ProviderEntry? {
        store.providers?.first(where: spec.match)
    }

    private var managedZones: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Managed channels")
                .font(.system(size: 13, weight: .medium))
            ForEach(Self.zoneSpecs, id: \.key) { spec in
                zoneCard(spec)
            }
        }
    }

    private func zoneCard(_ spec: ZoneSpec) -> some View {
        let entry = zoneEntry(spec)
        let enabled = !(entry?.disabled ?? false)
        let models = entry?.models ?? []
        let owner = spec.followEntryName
            ? (entry?.name.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? spec.aliasOwner
            : spec.aliasOwner
        return DisclosureCard(
            title: spec.title,
            subtitle: models.isEmpty ? "no models pinned — pass-through"
                : "\(models.count) model\(models.count == 1 ? "" : "s") pinned",
            trailing: models.isEmpty ? "pass-through" : "\(models.count) pinned",
            badges: enabled ? [] : ["off"],
            dimmed: !enabled,
            isExpanded: ui.isExpanded(spec.key),
            onToggle: { ui.setExpanded(spec.key, !ui.isExpanded(spec.key)) }
        ) {
            HStack(spacing: 6) {
                Text("Enabled").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { on in
                        store.editZone(match: spec.match, blank: spec.blank) { entry in
                            var updated = entry
                            updated.disabled = !on
                            return updated
                        }
                    }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        } content: {
            ModelZoneView(
                zoneKey: spec.key,
                entryProvider: { zoneEntry(spec) },
                aliasOwner: {
                    guard spec.followEntryName,
                          let name = zoneEntry(spec)?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty
                    else { return owner }
                    return name
                },
                emptyHint: spec.emptyHint,
                fetchUpstream: {
                    let fetched = try await ProvidersPanelStore.shared.fetchZoneModels(kind: spec.fetchKind)
                    if spec.presets {
                        ProvidersPanelStore.shared.updateAntigravityLevels(from: fetched)
                    }
                    return fetched
                },
                presetEfforts: spec.presets ? { name in
                    ProvidersPanelStore.shared.antigravityLevels[name] ?? []
                } : nil,
                onChange: { change in
                    store.editZone(match: spec.match, blank: spec.blank, change: change)
                })
        }
    }

    private var endpoints: [(index: Int, entry: ProviderEntry)] {
        (store.providers ?? []).enumerated().filter { !$0.element.isManaged }.map { (index: $0.offset, entry: $0.element) }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("API key providers")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Button("Add provider", systemImage: "plus") { store.addProvider() }
                    .controlSize(.small)
            }
            if endpoints.isEmpty {
                Text("No API key providers configured. Add one to route models through an OpenAI-compatible or Responses endpoint.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(endpoints, id: \.entry.id) { item in
                    providerCard(index: item.index, provider: item.entry)
                }
            }
        }
    }

    private func providerCard(index: Int, provider: ProviderEntry) -> some View {
        let key = Self.providerKey(index)
        let kind = provider.kind ?? "openai"
        let models = provider.models
        let keys = provider.apiKeyEntries
        let enabled = provider.disabled != true
        var summary = models.isEmpty ? "pass-through" : "\(models.count) model\(models.count == 1 ? "" : "s")"
        if !keys.isEmpty {
            summary += " · \(keys.count) key\(keys.count == 1 ? "" : "s")"
        }
        return DisclosureCard(
            title: provider.name,
            monospacedTitle: true,
            subtitle: provider.baseUrl?.isEmpty == false ? provider.baseUrl! : "no base url",
            trailing: summary,
            badges: [kind == "responses" ? "responses" : "openai"] + (provider.disabled == true ? ["off"] : []),
            dimmed: provider.disabled == true,
            isExpanded: ui.isExpanded(key),
            onToggle: { ui.setExpanded(key, !ui.isExpanded(key)) }
        ) {
            HStack(spacing: 6) {
                Text("Enabled").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { on in
                        store.updateProvider(index: index) { entry in
                            var updated = entry
                            updated.disabled = !on
                            return updated
                        }
                    }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                Button {
                    ui.pendingRemoval = index
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Remove \(provider.name.isEmpty ? "this provider" : provider.name)")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                providerEditor(index: index, provider: provider)
                keyEditor(index: index, keys: keys)
                ModelZoneView(
                    zoneKey: key,
                    entryProvider: { providerEntry(index) },
                    aliasOwner: { providerEntry(index)?.name ?? "" },
                    emptyHint: "No models — every upstream model is passed through.",
                    fetchUpstream: { try await ProvidersPanelStore.shared.fetchProviderModels(index: index) },
                    presetEfforts: nil,
                    onChange: { change in store.updateProvider(index: index, change) })
            }
        }
        .onAppear {
            if provider.name.isEmpty, index == endpoints.first?.index {
                _ = ui.autoExpandOnce(key)
            }
        }
    }

    private func providerEntry(_ index: Int) -> ProviderEntry? {
        guard let list = store.providers, index < list.count else { return nil }
        return list[index]
    }

    private func providerEditor(index: Int, provider: ProviderEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            editorField("Name", placeholder: "e.g. openrouter", text: Binding(
                get: { provider.name },
                set: { text in
                    store.updateProvider(index: index) { entry in
                        var updated = entry
                        updated.name = text
                        return PanelLogic.smartDefault(old: entry, next: updated)
                    }
                }))
            editorField("Base URL", placeholder: "https://api.example.com/v1", text: Binding(
                get: { provider.baseUrl ?? "" },
                set: { text in
                    store.updateProvider(index: index) { entry in
                        var updated = entry
                        updated.baseUrl = text
                        return PanelLogic.smartDefault(old: entry, next: updated)
                    }
                }))
            VStack(alignment: .leading, spacing: 4) {
                FormLabel(text: "Kind")
                Picker("", selection: Binding(
                    get: { provider.kind == "responses" ? "responses" : "openai" },
                    set: { newValue in
                        store.updateProvider(index: index) { entry in
                            var updated = entry
                            updated.kind = newValue
                            return PanelLogic.smartDefault(old: entry, next: updated)
                        }
                    })) {
                    Text("OpenAI-compatible endpoint").tag("openai")
                    Text("OpenAI Responses endpoint").tag("responses")
                }
                .labelsHidden()
                .controlSize(.small)
                .font(RavenFont.mono(11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editorField(_ label: String, placeholder: String,
                             text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FormLabel(text: label)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(RavenFont.mono(12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyEditor(index: Int, keys: [ApiKeyEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FormLabel(text: "API keys")
                Spacer(minLength: 8)
                Button("Add key", systemImage: "plus") {
                    store.updateProvider(index: index) { entry in
                        var updated = entry
                        updated.apiKeyEntries = entry.apiKeyEntries + [ApiKeyEntry(apiKey: "")]
                        return updated
                    }
                }
                .controlSize(.small)
            }
            if keys.isEmpty {
                Text("None.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(keys.enumerated()), id: \.offset) { keyIndex, keyEntry in
                    HStack(spacing: 8) {
                        TextField("sk-…", text: Binding(
                            get: { keyEntry.apiKey },
                            set: { text in
                                store.updateProvider(index: index) { entry in
                                    var updated = entry
                                    guard keyIndex < updated.apiKeyEntries.count else { return entry }
                                    updated.apiKeyEntries[keyIndex].apiKey = text
                                    return updated
                                }
                            }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(RavenFont.mono(11))
                        Button {
                            store.updateProvider(index: index) { entry in
                                var updated = entry
                                updated.apiKeyEntries = entry.apiKeyEntries.enumerated()
                                    .filter { $0.offset != keyIndex }.map(\.element)
                                return updated
                            }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .help("Remove this API key")
                    }
                }
            }
        }
    }
}
