import SwiftUI

struct ProviderDetail: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        if store.providers.isEmpty {
            WelcomeView()
        } else if let provider = store.selectedProvider {
            ProviderPane(provider: provider)
        } else {
            ContentUnavailableView("Select a provider",
                                   systemImage: "sidebar.left",
                                   description: Text("Choose a provider on the left to see its models."))
        }
    }
}

struct ProviderPane: View {
    @Environment(ProviderStore.self) private var store
    let provider: Provider

    var body: some View {
        @Bindable var store = store
        ModelsSection(provider: provider)
            .safeAreaBar(edge: .bottom) {
                LaunchBar()
            }
            .navigationTitle(provider.name)
            .navigationSubtitle(provider.host)
            .searchable(text: $store.modelSearch, prompt: "Filter models")
            .toolbar {
                ToolbarItem {
                    if store.isLoading(provider) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Refresh Models", systemImage: "arrow.clockwise") {
                            Task { await store.refresh(provider) }
                        }
                    }
                }
                ToolbarSpacer(.fixed)
                ToolbarItemGroup {
                    Button("Edit Provider", systemImage: "square.and.pencil") {
                        store.beginEditing(provider)
                    }
                    Button("Remove Provider", systemImage: "trash", role: .destructive) {
                        store.pendingRemoval = provider
                    }
                }
            }
    }
}

struct ModelsSection: View {
    @Environment(ProviderStore.self) private var store
    let provider: Provider

    var body: some View {
        if let error = store.error(for: provider) {
            ContentUnavailableView {
                Label("Could not fetch models", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
                    .font(.callout)
                    .monospaced()
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") {
                    Task { await store.refresh(provider) }
                }
                .buttonStyle(.glassProminent)
            }
        } else if store.selectedModels.isEmpty && store.isLoading(provider) {
            ProgressView("Fetching models…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.selectedModels.isEmpty {
            ContentUnavailableView {
                Label("No models", systemImage: "tray")
            } description: {
                Text("\(provider.name) returned an empty model list.")
            } actions: {
                Button("Refresh") {
                    Task { await store.refresh(provider) }
                }
                .buttonStyle(.glass)
            }
        } else if store.groupedModels.isEmpty {
            ContentUnavailableView.search(text: store.modelSearch)
        } else {
            ModelList()
        }
    }
}

struct ModelList: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedModelID) {
            ForEach(store.groupedModels) { group in
                Section(group.owner) {
                    ForEach(group.models) { entry in
                        ModelRow(entry: entry, badge: store.windowBadge(for: entry))
                            .tag(entry.modelID)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

struct ModelRow: View {
    @Environment(ProviderStore.self) private var store
    let entry: ModelEntry
    let badge: WindowBadge

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.modelID)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                store.beginEditingWindow(for: entry)
            } label: {
                WindowBadgeView(badge: badge)
            }
            .buttonStyle(.plain)
            .help("Set context window")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Set Context Window…", systemImage: "slider.horizontal.3") {
                store.beginEditingWindow(for: entry)
            }
            if badge.isOverride {
                Button("Reset to Advertised", systemImage: "arrow.uturn.backward") {
                    store.resetWindow(for: entry)
                }
            }
        }
    }
}

struct WindowBadgeView: View {
    let badge: WindowBadge

    var body: some View {
        HStack(spacing: 3) {
            if badge.isOverride {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(badge.label)
        }
        .font(.caption)
        .foregroundStyle(badge.isOverride ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((badge.isOverride ? Color.orange : Color.gray).opacity(0.14), in: .capsule)
    }
}

struct LaunchBar: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        @Bindable var store = store
        GlassEffectContainer {
            VStack(spacing: 10) {
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
                    .fixedSize()
                    Spacer()
                    Button(store.workdirLabel, systemImage: "folder") {
                        store.isChoosingWorkdir = true
                    }
                    .buttonStyle(.glass)
                    .help("Working directory: \(store.workdir.path(percentEncoded: false))")
                }
                HStack(spacing: 10) {
                    LaunchSummary()
                    Spacer()
                    Button("Launch", systemImage: "play.fill") {
                        store.launch()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.selectedModelValid)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

struct LaunchSummary: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        if store.selectedModelValid, let model = store.selectedModelID {
            Label {
                Text("\(Text("Ready · ").foregroundStyle(.secondary))\(Text(model).monospaced())")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label("Pick a model above to launch", systemImage: "arrow.up")
                .foregroundStyle(.secondary)
        }
    }
}

struct WelcomeView: View {
    @Environment(ProviderStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Raven", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Add a provider — a name, base URL, and API key — and Raven fetches its models, then launches Claude Code or Codex against the one you pick.")
                .frame(maxWidth: 380)
        } actions: {
            Button("Add Your First Provider", systemImage: "plus") {
                store.beginAddingProvider()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}
