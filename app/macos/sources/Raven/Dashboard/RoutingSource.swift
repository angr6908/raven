import SwiftUI

struct SourceDetail: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let source: RouteSource

    var body: some View {
        VStack(spacing: 0) {
            SourceHeader(source: source)
            Divider()
            if case .provider(let id) = source, nav.tab == .connection {
                ConnectionForm(id: id)
            } else {
                ModelsEditor(source: source)
            }
        }
        .task {
            if source == .channel("antigravity") { store.loadAntigravityLevels() }
        }
    }
}

private struct SourceHeader: View {
    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    @Environment(AppModel.self) private var app
    let source: RouteSource

    var body: some View {
        @Bindable var nav = nav
        let entry = store.entry(source)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Glyph(symbol: symbol, tint: entry?.disabled == true ? .secondary : tint(entry), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(entry))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.md)
                Toggle("Enabled", isOn: Binding(
                    get: { entry?.disabled != true },
                    set: { store.setEnabled(source, $0) }))
                    .toggleStyle(.switch)
                    .help("Off leaves this source's models out of /v1/models, so launchers stop offering them")
            }
            HStack(spacing: Space.md) {
                switch source {
                case .provider:
                    Picker("Section", selection: $nav.tab) {
                        ForEach(SourceTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                case .channel:
                    Button("Accounts", systemImage: "person.2.badge.key") { app.page = .accounts }
                        .help("Sign in or out of the accounts this channel rotates through")
                }
                Spacer(minLength: Space.md)
                if nav.tab == .models || isChannel {
                    SmartAliasToggle(source: source)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var isChannel: Bool {
        if case .channel = source { return true }
        return false
    }

    private var symbol: String {
        if case .channel(let kind) = source { return ChannelSpec.spec(for: kind)?.symbol ?? "cpu" }
        return "server.rack"
    }

    private func tint(_ entry: ProviderEntry?) -> Color {
        if case .channel(let kind) = source { return ChannelSpec.spec(for: kind)?.tint ?? .teal }
        return RouteTint.color(entry?.name ?? "")
    }

    private func title(_ entry: ProviderEntry?) -> String {
        if case .channel(let kind) = source { return ChannelSpec.spec(for: kind)?.title ?? kind }
        return entry.map(RoutingTable.sourceName) ?? "Provider"
    }

    private func subtitle(_ entry: ProviderEntry?) -> String {
        let count = entry?.models.count ?? 0
        let models = count == 1 ? "1 model" : "\(count) models"
        switch source {
        case .channel:
            return "Managed channel · \(models)"
        case .provider:
            guard let entry else { return models }
            let kind = entry.usableKind == "responses" ? "Responses" : "Chat Completions"
            let base = (entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
            let host = URL(string: base)?.host() ?? (base.isEmpty ? "No base URL" : base)
            return [kind, host, models].joined(separator: " · ")
        }
    }
}

private struct SmartAliasToggle: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource

    var body: some View {
        let owner = store.owner(source)
        Toggle("Smart Aliases", isOn: Binding(
            get: { store.smartAliasOn(source) },
            set: { store.setSmartAlias(source, $0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(owner.isEmpty || (store.entry(source)?.models.isEmpty ?? true))
            .help(owner.isEmpty ? "Name the provider first"
                  : "Expose each model as its name without the vendor prefix, plus @\(owner)")
    }
}

private struct ConnectionForm: View {
    enum TestState: Equatable {
        case idle, testing, success(Int), failure(String)
    }

    private let store = ProvidersPanelStore.shared
    private let nav = RoutingNavigation.shared
    let id: UUID
    @State private var reveal = false
    @State private var test = TestState.idle
    @FocusState private var nameFocused: Bool

    var body: some View {
        let source = RouteSource.provider(id)
        if let entry = store.entry(source), let index = store.index(of: source) {
            let issues = RoutingTable.issues(at: index, in: store.list)
            Form {
                Section {
                    TextField("Name", text: Binding(
                        get: { entry.name },
                        set: { text in store.editSmart(source) { $0.name = text } }),
                        prompt: Text(verbatim: "openrouter"))
                        .font(.identifier)
                        .focused($nameFocused)
                    TextField("Base URL", text: Binding(
                        get: { entry.baseUrl ?? "" },
                        set: { text in store.edit(source) { $0.baseUrl = text } }),
                        prompt: Text(verbatim: "https://api.example.com/v1"))
                        .font(.identifier)
                    Picker("Protocol", selection: Binding(
                        get: { entry.usableKind },
                        set: { value in store.edit(source) { $0.kind = value } })) {
                        Text("Chat Completions").tag("openai")
                        Text("Responses").tag("responses")
                    }
                } header: {
                    Text("Endpoint")
                } footer: {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(issues.filter { $0 != .missingKey }, id: \.self) { issue in
                            Label(issue.message, systemImage: issue.blocking ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.blocking ? .red : .orange)
                        }
                        if let endpoint = RoutingTable.endpoint(entry), !issues.contains(.invalidURL) {
                            Text("Requests post to \(endpoint)")
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section {
                    if entry.apiKeyEntries.isEmpty {
                        LabeledContent("Active Key") {
                            Button("Add Key") {
                                store.edit(source) { $0.apiKeyEntries.append(ApiKeyEntry(apiKey: "")) }
                            }
                        }
                    }
                    ForEach(entry.apiKeyEntries.indices, id: \.self) { keyIndex in
                        KeyRow(source: source, index: keyIndex, entry: entry.apiKeyEntries[keyIndex],
                               count: entry.apiKeyEntries.count, reveal: reveal)
                    }
                    HStack {
                        Button("Add Spare Key", systemImage: "key") {
                            store.edit(source) { $0.apiKeyEntries.append(ApiKeyEntry(apiKey: "")) }
                        }
                        .disabled(entry.apiKeyEntries.isEmpty)
                        Spacer()
                        Button(reveal ? "Hide Keys" : "Show Keys", systemImage: reveal ? "eye.slash" : "eye") {
                            reveal.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("API Keys")
                } footer: {
                    if issues.contains(.missingKey) {
                        Label(ProviderIssue.missingKey.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Raven signs every request with the active key. Spares stay in the routing doc; promote one to swap.")
                    }
                }

                Section {
                    HStack(spacing: Space.md) {
                        TestStatus(state: test)
                        Spacer(minLength: Space.md)
                        Button("Test Connection") { run(index: index) }
                            .disabled(test == .testing || issues.contains(where: \.blocking))
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Saves pending edits, then lists the models at \(modelsURL(entry)).")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section {
                    HStack {
                        Button("Duplicate Provider", systemImage: "plus.square.on.square") {
                            if let copy = store.duplicate(id) { nav.open(.provider(copy), tab: .connection) }
                        }
                        Spacer()
                        Button("Remove Provider…", systemImage: "trash", role: .destructive) { nav.removing = id }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if entry.name.isEmpty { nameFocused = true }
            }
        }
    }

    private func modelsURL(_ entry: ProviderEntry) -> String {
        var base = (entry.baseUrl ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base.isEmpty ? "the base URL’s /models" : base + "/models"
    }

    private func run(index: Int) {
        test = .testing
        Task {
            do {
                let models = try await store.catalog(for: .provider(id))
                test = .success(models.count)
            } catch {
                test = .failure((error as? PanelError)?.noticeText ?? error.localizedDescription)
            }
        }
    }
}

private struct KeyRow: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource
    let index: Int
    let entry: ApiKeyEntry
    let count: Int
    let reveal: Bool

    var body: some View {
        LabeledContent(index == 0 ? "Active Key" : "Spare Key \(index)") {
            HStack(spacing: Space.sm) {
                Group {
                    if reveal {
                        TextField("API Key", text: binding, prompt: Text(verbatim: "sk-…"))
                    } else {
                        SecureField("API Key", text: binding, prompt: Text(verbatim: "sk-…"))
                    }
                }
                .labelsHidden()
                .font(.identifier)
                if index > 0 {
                    Button("Make Active") {
                        store.edit(source) { provider in
                            guard index < provider.apiKeyEntries.count else { return }
                            let key = provider.apiKeyEntries.remove(at: index)
                            provider.apiKeyEntries.insert(key, at: 0)
                        }
                    }
                    .help("Sign requests with this key instead")
                }
                if count > 1 || !entry.apiKey.isEmpty {
                    Button(role: .destructive) {
                        store.edit(source) { provider in
                            guard index < provider.apiKeyEntries.count else { return }
                            provider.apiKeyEntries.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this key")
                }
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { entry.apiKey },
            set: { text in
                store.edit(source) { provider in
                    guard index < provider.apiKeyEntries.count else { return }
                    provider.apiKeyEntries[index].apiKey = text
                }
            })
    }
}

private struct TestStatus: View {
    let state: ConnectionForm.TestState

    var body: some View {
        switch state {
        case .idle:
            Label("Not tested", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success(let count):
            Label(count == 1 ? "Connected · 1 model upstream" : "Connected · \(count) models upstream",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.good)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }
}
