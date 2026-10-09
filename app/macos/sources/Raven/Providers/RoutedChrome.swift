import SwiftUI

extension RouteStatus {
    var tint: Color {
        switch self {
        case .active: Palette.good
        case .hidden: .secondary
        case .incomplete, .duplicate, .shadowed: .orange
        }
    }

    var symbol: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .hidden: "eye.slash"
        case .incomplete: "exclamationmark.triangle.fill"
        case .duplicate: "square.on.square"
        case .shadowed: "arrow.triangle.merge"
        }
    }
}

extension View {
    func routedChrome(_ source: RouteSource?) -> some View {
        modifier(RoutedChrome(source: source))
    }
}

private struct RoutedChrome: ViewModifier {
    private let panel = ProvidersPanelStore.shared
    @Environment(AppModel.self) private var app
    @AppStorage("models.inspector") private var showsInspector = true
    let source: RouteSource?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if let source, showsInspector {
                Divider()
                RoutedInspector(source: source)
                    .frame(width: 300)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let source {
                if let message = panel.error {
                    Notice(message: message).padding(Space.md)
                } else if panel.blocked(source) {
                    Notice(message: "This provider's connection is incomplete. Choose Edit… to finish it.",
                           severity: .warning)
                        .padding(Space.md)
                } else if let message = panel.syncErrors[source] {
                    Notice(message: "Couldn't fetch the catalog: \(message)").padding(Space.md)
                }
            }
        }
        .toolbar {
            if let source {
                if case .failed(let message) = panel.saver.status {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry Save", systemImage: "exclamationmark.triangle.fill") { panel.scheduleSave() }
                            .tint(.red)
                            .help("Couldn't save providers: \(message)")
                    }
                }
                if panel.syncing.contains(source) {
                    ToolbarItem(placement: .primaryAction) {
                        ProgressView()
                            .controlSize(.small)
                            .help("Fetching the catalog…")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    FillButton(source: source)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        SourceMenu(source: source)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("More")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
                        .help(showsInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
        }
        .alert("Couldn't Reach models.dev", isPresented: Binding(
            get: { source != nil && ModelFiller.shared.note != nil },
            set: { if !$0 { ModelFiller.shared.dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ModelFiller.shared.note ?? "")
        }
        .onChange(of: panel.ids) {
            if case .provider(let id)? = source, panel.providers != nil, !panel.ids.contains(id) {
                app.page = .models
            }
        }
        .task(id: source) {
            guard let source else { return }
            panel.start()
            panel.sync(source)
            if source == .channel("antigravity") { panel.loadAntigravityLevels() }
        }
    }
}

private struct FillButton: View {
    private let filler = ModelFiller.shared
    let source: RouteSource

    var body: some View {
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
            let count = ProvidersPanelStore.shared.entry(source)?.models.count ?? 0
            Button("Fill All from models.dev", systemImage: "arrow.down.to.line") {
                filler.fill(source, rows: Array(0..<count))
            }
            .disabled(count == 0)
            .help("Fill All from models.dev")
        }
    }
}

private struct RoutedInspector: View {
    private let panel = ProvidersPanelStore.shared
    @Environment(ProviderStore.self) private var store
    let source: RouteSource

    var body: some View {
        if let ref = store.selection, ref.providerID == LocalProxy.providerID,
           let index = panel.modelIndex(source, clientID: ref.modelID),
           let model = panel.entry(source)?.models[index] {
            RoutedModelForm(source: source, index: index, model: model)
                .id(ref)
        } else {
            ContentUnavailableView("No Model Selected", systemImage: "sidebar.right",
                                   description: Text("Select a model to edit how Raven routes it."))
        }
    }
}

private struct RoutedModelForm: View {
    private let panel = ProvidersPanelStore.shared
    private let filler = ModelFiller.shared
    let source: RouteSource
    let index: Int
    let model: ProviderModelDef

    var body: some View {
        Form {
            Section {
                LabeledContent("Upstream Model") {
                    Text(model.name)
                        .font(.identifier)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Model ID") {
                    Text(RoutingTable.clientID(model))
                        .font(.identifier)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let status = panel.status(source, model: index), status.isProblem {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.title)
                            Text(status.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: status.symbol).foregroundStyle(status.tint)
                    }
                }
            }
            Section("Context Window") {
                ContextCell(value: model.maxContextLength) { tokens in
                    panel.updateModel(source, at: index) { $0 = PanelLogic.withContext($0, tokens: tokens) }
                }
            }
            Section("Reasoning Effort") {
                if source == .channel("antigravity") {
                    let preset = panel.antigravityLevels[model.name]
                    Text(preset.map { $0.isEmpty ? "None" : RoutingTable.effortSummary($0, order: panel.effortLevels) }
                         ?? "Preset")
                        .foregroundStyle(.secondary)
                        .help("Antigravity fixes the levels per model. Clients pick one per request.")
                } else {
                    EffortPicker(source: source, index: index)
                }
            }
            Section {
                Button("Fill from models.dev") { filler.fill(source, rows: [index]) }
                    .disabled(filler.running)
            }
        }
        .formStyle(.grouped)
    }
}

struct ReasoningBadge: View {
    private let panel = ProvidersPanelStore.shared
    let source: RouteSource
    let item: ModelItem
    @State private var open = false

    var body: some View {
        if let index = panel.modelIndex(source, clientID: item.entry.modelID),
           let model = panel.entry(source)?.models[index] {
            let order = panel.effortLevels
            if source == .channel("antigravity") {
                let preset = panel.antigravityLevels[model.name]
                Label(preset.map { $0.isEmpty ? "None" : RoutingTable.effortSummary($0, order: order) } ?? "Preset",
                      systemImage: "brain")
                    .font(.figure)
                    .foregroundStyle(.secondary)
                    .help("Antigravity fixes the levels per model. Clients pick one per request.")
            } else {
                let levels = model.thinking?.levels ?? []
                Button {
                    open = true
                } label: {
                    HStack(spacing: 3) {
                        Label(RoutingTable.effortSummary(levels, order: order), systemImage: "brain")
                            .font(.figure)
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
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Reasoning Effort").font(.headline)
                        EffortPicker(source: source, index: index)
                    }
                    .padding(Space.lg)
                }
                .help("Reasoning levels clients may request")
            }
        }
    }
}

struct RoutedModelMenu: View {
    private let panel = ProvidersPanelStore.shared
    private let filler = ModelFiller.shared
    @Environment(AppModel.self) private var app
    let source: RouteSource
    let item: ModelItem

    var body: some View {
        if let index = panel.modelIndex(source, clientID: item.entry.modelID),
           let model = panel.entry(source)?.models[index] {
            Divider()
            Button("Fill from models.dev") { filler.fill(source, rows: [index]) }
                .disabled(filler.running)
            Button("Copy Upstream Name", systemImage: "document.on.document") { app.copy(model.name) }
        }
    }
}

struct SourceMenu: View {
    private let store = ProvidersPanelStore.shared
    @Environment(AppModel.self) private var app
    let source: RouteSource

    var body: some View {
        switch source {
        case .channel:
            Button("Manage Accounts…") { app.page = .accounts }
            Divider()
            enabledToggle
        case .provider(let id):
            let upstreams = store.upstreams
            let position = upstreams.firstIndex { $0.id == id } ?? 0
            Button("Edit…") { app.edit(upstream: id) }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let copy = store.duplicate(id) { app.page = .source(.provider(copy)) }
            }
            Divider()
            enabledToggle
            Divider()
            Button("Move Up") { store.moveUpstream(id, by: -1) }
                .disabled(position == 0)
            Button("Move Down") { store.moveUpstream(id, by: 1) }
                .disabled(position >= upstreams.count - 1)
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) { app.sourceRemoval = id }
        }
    }

    private var enabledToggle: some View {
        Toggle("Enabled", isOn: Binding(
            get: { store.entry(source)?.disabled != true },
            set: { store.setEnabled(source, $0) }))
    }
}
