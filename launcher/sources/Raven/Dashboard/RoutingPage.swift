import SwiftUI

struct RoutingPage: View {
    private let store = ProvidersPanelStore.shared
    @State private var expanded: Set<String> = []
    @State private var removingIndex: Int?

    var body: some View {
        Group {
            if let providers = store.providers {
                Form {
                    Section("Channels") {
                        ForEach(ZoneSpec.managed, id: \.key) { spec in
                            ManagedRow(spec: spec, expanded: binding(spec.key))
                        }
                    }
                    Section("API Providers") {
                        ForEach(Array(providers.enumerated()).filter { !$0.element.isManaged }, id: \.element.id) { index, entry in
                            ProviderRow(index: index, provider: entry, expanded: binding("p:\(index)"),
                                        removingIndex: $removingIndex)
                        }
                        Button("Add Provider", systemImage: "plus") {
                            store.addProvider()
                            expanded = ["p:0"]
                        }
                    }
                }
                .formStyle(.grouped)
            } else if let error = store.error {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't Load Routing", message: error) {
                    Button("Try Again") { store.reload() }
                }
            } else {
                LoadingState(message: "Loading providers…")
            }
        }
        .navigationTitle("Routing")
        .navigationSubtitle(summary)
        .confirmationDialog("Remove this provider?", isPresented: Binding(
            get: { removingIndex != nil }, set: { if !$0 { removingIndex = nil } }), presenting: removingIndex) { index in
            Button("Remove Provider", role: .destructive) {
                expanded.removeAll()
                store.removeProvider(index: index)
            }
        } message: { _ in
            Text("Its models and API keys are dropped from the routing doc on save.")
        }
        .onAppear { store.start() }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open { expanded.insert(key) } else { expanded.remove(key) }
            })
    }

    private var summary: String {
        guard let providers = store.providers else { return "" }
        let models = providers.reduce(0) { $0 + $1.models.count }
        return models == 1 ? "1 pinned model" : "\(models) pinned models"
    }
}

private struct RowLabel: View {
    let title: String
    let subtitle: String
    var mono = false
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(mono ? .identifier : .body)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            Toggle("Enabled", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

private func modelCount(_ entry: ProviderEntry?) -> String {
    guard let entry, !entry.models.isEmpty else { return "Passes every model through" }
    return entry.models.count == 1 ? "1 model" : "\(entry.models.count) models"
}

private struct ManagedRow: View {
    private let store = ProvidersPanelStore.shared
    let spec: ZoneSpec
    @Binding var expanded: Bool

    var body: some View {
        let entry = store.providers?.first(where: spec.match)
        let context = ModelsContext(
            entry: { store.providers?.first(where: spec.match) },
            aliasOwner: { spec.kind },
            emptyHint: spec.emptyHint,
            fetchUpstream: {
                let fetched = try await store.fetchZoneModels(kind: spec.kind)
                if spec.presets { store.updateAntigravityLevels(from: fetched) }
                return fetched
            },
            presetEfforts: spec.presets ? { store.antigravityLevels[$0] ?? [] } : nil,
            onChange: { store.editZone(match: spec.match, blank: spec.blank, change: $0) })
        DisclosureGroup(isExpanded: $expanded) {
            ModelsList(context: context)
        } label: {
            RowLabel(title: spec.title, subtitle: modelCount(entry),
                     enabled: Binding(
                        get: { entry?.disabled != true },
                        set: { on in
                            store.editZone(match: spec.match, blank: spec.blank) { entry in
                                var updated = entry
                                updated.disabled = !on
                                return updated
                            }
                        }))
        }
    }
}

private struct ProviderRow: View {
    private let store = ProvidersPanelStore.shared
    let index: Int
    let provider: ProviderEntry
    @Binding var expanded: Bool
    @Binding var removingIndex: Int?
    @State private var reveal = false

    var body: some View {
        let context = ModelsContext(
            entry: { store.providers.flatMap { index < $0.count ? $0[index] : nil } },
            aliasOwner: { store.providers.flatMap { index < $0.count ? $0[index].name : nil } ?? "" },
            emptyHint: "No models listed. Every upstream model is passed through.",
            fetchUpstream: { try await store.fetchProviderModels(index: index) },
            presetEfforts: nil,
            onChange: { store.updateProvider(index: index, $0) })
        DisclosureGroup(isExpanded: $expanded) {
            LabeledContent("Name") {
                TextField("Name", text: Binding(
                    get: { provider.name }, set: { text in smart { $0.name = text } }),
                    prompt: Text("openrouter"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Base URL") {
                TextField("Base URL", text: Binding(
                    get: { provider.baseUrl ?? "" }, set: { text in smart { $0.baseUrl = text } }),
                    prompt: Text("https://api.example.com/v1"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            Picker("Protocol", selection: Binding(
                get: { provider.kind == "responses" ? "responses" : "openai" },
                set: { value in smart { $0.kind = value } })) {
                Text("Chat Completions").tag("openai")
                Text("Responses").tag("responses")
            }
            ForEach(Array(provider.apiKeyEntries.enumerated()), id: \.offset) { keyIndex, entry in
                LabeledContent("API Key") {
                    HStack(spacing: Space.sm) {
                        Group {
                            if reveal {
                                TextField("API Key", text: keyBinding(keyIndex, entry), prompt: Text("sk-…"))
                            } else {
                                SecureField("API Key", text: keyBinding(keyIndex, entry), prompt: Text("sk-…"))
                            }
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        Button {
                            reveal.toggle()
                        } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(reveal ? "Hide keys" : "Show keys")
                        if provider.apiKeyEntries.count > 1 {
                            Button(role: .destructive) {
                                update { $0.apiKeyEntries.remove(at: keyIndex) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this key")
                        }
                    }
                }
            }
            Button("Add Another Key", systemImage: "key") {
                update { $0.apiKeyEntries.append(ApiKeyEntry(apiKey: "")) }
            }
            ModelsList(context: context)
            Button("Remove Provider…", role: .destructive) { removingIndex = index }
        } label: {
            RowLabel(title: provider.name, subtitle: subtitle, mono: true,
                     enabled: Binding(
                        get: { provider.disabled != true },
                        set: { on in update { $0.disabled = !on } }))
        }
    }

    private var subtitle: String {
        var parts = [modelCount(provider)]
        if let host = provider.baseUrl.flatMap({ URL(string: $0)?.host() }) { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private func update(_ change: @escaping (inout ProviderEntry) -> Void) {
        store.updateProvider(index: index) { entry in
            var updated = entry
            change(&updated)
            return updated
        }
    }

    private func smart(_ change: @escaping (inout ProviderEntry) -> Void) {
        store.updateProvider(index: index) { entry in
            var updated = entry
            change(&updated)
            return PanelLogic.smartDefault(old: entry, next: updated)
        }
    }

    private func keyBinding(_ keyIndex: Int, _ entry: ApiKeyEntry) -> Binding<String> {
        Binding(
            get: { entry.apiKey },
            set: { text in
                update { updated in
                    guard keyIndex < updated.apiKeyEntries.count else { return }
                    updated.apiKeyEntries[keyIndex].apiKey = text
                }
            })
    }
}
