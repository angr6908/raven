import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProviderStore

    @State private var showingAddProvider = false
    @State private var editingProvider: Provider?
    @State private var deletingProvider: Provider?
    @State private var editingWindow: WindowEditContext?
    @State private var launchError: String?
    @State private var modelSearch = ""
    @State private var workdir: URL = FileManager.default.homeDirectoryForCurrentUser

    struct WindowEditContext: Identifiable {
        var id: String { "\(providerID?.uuidString ?? "none")/\(modelID)" }
        var providerID: UUID?
        var modelID: String
        var current: Int?
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingAddProvider) {
            ProviderEditView(isEditing: false) { name, baseURL, apiKey in
                store.addProvider(name: name, baseURL: baseURL, apiKey: apiKey)
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditView(isEditing: true, provider: provider) { name, baseURL, apiKey in
                var updated = provider
                updated.name = name
                updated.baseURL = baseURL
                updated.apiKey = apiKey
                store.updateProvider(updated)
            }
        }
        .sheet(item: $editingWindow) { context in
            WindowEditView(context: context) { window in
                if let providerID = context.providerID {
                    store.setWindowOverride(providerID: providerID,
                                            modelID: context.modelID,
                                            contextWindow: window)
                }
            }
        }
        .confirmationDialog(
            "Remove this provider?",
            isPresented: Binding(
                get: { deletingProvider != nil },
                set: { if !$0 { deletingProvider = nil } }
            ),
            presenting: deletingProvider
        ) { provider in
            Button("Remove \(provider.name)", role: .destructive) {
                store.removeProvider(provider)
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Raven will forget \(provider.name)'s base URL and API key. This can't be undone.")
        }
        .alert("Launch failed", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchError ?? "")
        }
        .onAppear { ensureModelSelection() }
        .onChange(of: store.selectedProviderID) { _ in ensureModelSelection() }
        .onChange(of: store.models) { _ in ensureModelSelection() }
    }

    private var sidebar: some View {
        List(selection: $store.selectedProviderID) {
            Section("Providers") {
                ForEach(store.providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 360)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private func providerRow(_ provider: Provider) -> some View {
        HStack(spacing: 10) {
            statusDot(provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(statusSubtitle(provider))
                    .font(.caption)
                    .foregroundStyle(statusIsError(provider) ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Refresh") { Task { await store.refresh(provider) } }
            Button("Edit…") { editingProvider = provider }
            Divider()
            Button("Remove", role: .destructive) { deletingProvider = provider }
        }
    }

    private func statusDot(_ provider: Provider) -> some View {
        Group {
            if store.loading.contains(provider.id) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Circle().fill(statusColor(provider))
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func statusColor(_ provider: Provider) -> Color {
        if store.errors[provider.id] != nil { return .red }
        if (store.models[provider.id]?.isEmpty == false) { return .green }
        return .secondary
    }

    private func statusIsError(_ provider: Provider) -> Bool {
        store.errors[provider.id] != nil && !store.loading.contains(provider.id)
    }

    private func statusSubtitle(_ provider: Provider) -> String {
        if store.loading.contains(provider.id) { return "Loading models…" }
        if store.errors[provider.id] != nil { return "Couldn't connect" }
        let count = store.models[provider.id]?.count ?? 0
        if count == 0 { return "No models yet" }
        return count == 1 ? "1 model" : "\(count) models"
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button {
                showingAddProvider = true
            } label: {
                Label("Add Provider", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            Spacer()

            if !store.loading.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh all providers")
                .disabled(store.providers.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var detail: some View {
        Group {
            if store.providers.isEmpty {
                welcomeView
            } else if let provider = store.selectedProvider {
                providerPane(provider)
            } else {
                centered {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Select a provider")
                        .font(.headline)
                    Text("Choose a provider on the left to see its models.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func providerPane(_ provider: Provider) -> some View {
        VStack(spacing: 0) {
            modelsSection(provider)
            Divider()
            launchFooter(provider)
        }
        .navigationTitle(provider.name)
        .navigationSubtitle(host(provider))
        .searchable(text: $modelSearch, prompt: "Filter models")
        .toolbar {
            ToolbarItemGroup {
                if store.loading.contains(provider.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.refresh(provider) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh models")
                }
                Button {
                    editingProvider = provider
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Edit provider")
                Button(role: .destructive) {
                    deletingProvider = provider
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove provider")
            }
        }
    }

    private func modelsSection(_ provider: Provider) -> some View {
        Group {
            if let error = store.errors[provider.id], !store.loading.contains(provider.id) {
                centered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("Could not fetch models")
                        .font(.headline)
                    Text(error)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Try Again") { Task { await store.refresh(provider) } }
                        .buttonStyle(.borderedProminent)
                }
            } else if store.selectedModels.isEmpty && store.loading.contains(provider.id) {
                centered {
                    ProgressView()
                    Text("Fetching models…").foregroundStyle(.secondary)
                }
            } else if store.selectedModels.isEmpty {
                centered {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No models")
                        .font(.headline)
                    Text("\(provider.name) returned an empty model list.")
                        .foregroundStyle(.secondary)
                    Button("Refresh") { Task { await store.refresh(provider) } }
                }
            } else if groupedModels.isEmpty {
                centered {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.headline)
                    Text("No model matches “\(modelSearch)”.")
                        .foregroundStyle(.secondary)
                }
            } else {
                modelList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelList: some View {
        List(selection: $store.selectedModelID) {
            ForEach(groupedModels, id: \.0) { group in
                Section {
                    ForEach(group.1) { entry in
                        modelRow(entry).tag(entry.modelID)
                    }
                } header: {
                    Text(group.0)
                }
            }
        }
        .listStyle(.inset)
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        let info = windowInfo(entry)
        return HStack(spacing: 10) {
            Image(systemName: "cube")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(entry.modelID)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                editingWindow = WindowEditContext(providerID: store.selectedProviderID,
                                                  modelID: entry.modelID,
                                                  current: info.effective)
            } label: {
                windowPill(label: info.label, override: info.isOverride)
            }
            .buttonStyle(.plain)
            .help("Set context window")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Set Context Window…") {
                editingWindow = WindowEditContext(providerID: store.selectedProviderID,
                                                  modelID: entry.modelID,
                                                  current: info.effective)
            }
            if info.isOverride {
                Button("Reset to Advertised") {
                    if let providerID = store.selectedProviderID {
                        store.setWindowOverride(providerID: providerID,
                                                modelID: entry.modelID,
                                                contextWindow: nil)
                    }
                }
            }
        }
    }

    private func windowPill(label: String, override: Bool) -> some View {
        let tint: Color = override ? .orange : .gray
        return HStack(spacing: 3) {
            if override {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(override ? Color.orange : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    private func launchFooter(_ provider: Provider) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Run with")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Client", selection: $store.selectedClient) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)

                Spacer()

                Button {
                    chooseWorkdir()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(workdirLabel).lineLimit(1)
                    }
                }
                .help("Working directory: \(workdir.path)")
            }

            HStack(spacing: 10) {
                summaryLabel
                Spacer()
                Button {
                    launch()
                } label: {
                    Label("Launch", systemImage: "play.fill")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!selectedModelValid)
            }
        }
        .padding(14)
        .background(.bar)
    }

    private var summaryLabel: some View {
        Group {
            if selectedModelValid, let model = store.selectedModelID {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    (Text("Ready · ").foregroundColor(.secondary)
                        + Text(model).font(.system(.callout, design: .monospaced)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.secondary)
                    Text("Pick a model above to launch")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var welcomeView: some View {
        centered {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to Raven")
                .font(.title.bold())
            Text("Add a provider — a name, base URL, and API key — and Raven fetches its models, then launches Claude Code or Codex against the one you pick.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button {
                showingAddProvider = true
            } label: {
                Label("Add Your First Provider", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }

    private var workdirLabel: String {
        let name = workdir.lastPathComponent
        return name.isEmpty ? "Choose…" : name
    }

    private func host(_ provider: Provider) -> String {
        URL(string: provider.rootURL)?.host ?? provider.rootURL
    }

    private var selectedModelValid: Bool {
        guard let id = store.selectedModelID else { return false }
        return store.selectedModels.contains { $0.modelID == id }
    }

    private func windowInfo(_ entry: ModelEntry) -> (label: String, isOverride: Bool, effective: Int?) {
        let providerID = store.selectedProviderID
        let override = providerID.flatMap {
            store.windowOverride(providerID: $0, modelID: entry.modelID)
        }
        let effective = override ?? entry.contextWindow
        let isDefault = override == nil && entry.contextWindow == nil
        let label = isDefault
            ? "\(Self.windowLabel(Launcher.fallbackContextWindow)) default"
            : Self.windowLabel(effective ?? Launcher.fallbackContextWindow)
        return (label, override != nil, effective)
    }

    static func windowLabel(_ tokens: Int) -> String {
        let thousand = 1_000, million = 1_000_000
        if tokens >= million, tokens % million == 0 {
            return "\(tokens / million)M ctx"
        }
        if tokens >= thousand, tokens % thousand == 0 {
            return "\(tokens / thousand)K ctx"
        }
        return "\(tokens) ctx"
    }

    private var groupedModels: [(String, [ModelEntry])] {
        let query = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? store.selectedModels : store.selectedModels.filter {
            $0.modelID.lowercased().contains(query)
                || ($0.ownedBy ?? "").lowercased().contains(query)
        }
        let groups = Dictionary(grouping: filtered) { $0.ownedBy ?? "other" }
        return groups
            .map { ($0.key, $0.value.sorted { $0.modelID < $1.modelID }) }
            .sorted { $0.0 < $1.0 }
    }

    private func ensureModelSelection() {
        let models = store.selectedModels
        guard !models.isEmpty else { return }
        if !models.contains(where: { $0.modelID == store.selectedModelID }) {
            store.selectedModelID = models.first?.modelID
        }
    }

    private func chooseWorkdir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workdir
        panel.prompt = "Use Folder"
        panel.message = "Choose the working directory for the launched client"
        if panel.runModal() == .OK, let url = panel.url {
            workdir = url
        }
    }

    private func launch() {
        guard let provider = store.selectedProvider,
              let model = store.selectedModelID,
              selectedModelValid else { return }
        do {
            try Launcher.launch(provider: provider, model: model,
                                client: store.selectedClient, workdir: workdir)
        } catch {
            launchError = error.localizedDescription
        }
    }
}
