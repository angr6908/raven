import SwiftUI

nonisolated extension PricingRowData: Identifiable {
    var id: String { model }
    var inputRate: Double { price.input }
    var outputRate: Double { price.output }
    var cachedRate: Double { price.cached }
    var peakRank: Int { peak ? 1 : 0 }
    var needsPrice: Bool { !priced && inLog }
}

@Observable
final class PricingEditor {
    var fetching: Set<String> = []
    var fetchingAll = false
    private var drafts: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func draft(_ key: String, _ fallback: String) -> String { drafts[key] ?? fallback }

    func set(_ key: String, _ value: String, commit: @escaping (String) -> Void) {
        drafts[key] = value
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit(value)
        }
    }
}

struct PricingPage: View {
    private let store = PricingStore.shared
    @Environment(AppModel.self) private var app
    @State private var editor = PricingEditor()
    @State private var sort = [KeyPathComparator(\PricingRowData.model)]

    var body: some View {
        @Bindable var app = app
        let all = store.rows()
        let rows = all
            .filter { app.query.isEmpty || $0.model.lowercased().contains(app.query) }
            .sorted(using: sort)
        Group {
            if store.loading {
                LoadingState(message: "Loading prices…")
            } else if all.isEmpty {
                EmptyState(symbol: "dollarsign", title: "No Prices Yet",
                           message: "Models appear here once they show up in the request log or the routing table.")
            } else {
                table(rows)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.error ?? saveFailure {
                Notice(message: message).padding(Space.md)
            }
        }
        .navigationTitle("Pricing")
        .searchable(text: $app.search, placement: .toolbar, prompt: "Filter models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Fetch All Prices", systemImage: "arrow.down.to.line") { fetchAll(all) }
                    .disabled(editor.fetchingAll || all.isEmpty)
                    .help("Fetch every price from models.dev")
            }
            ToolbarItem(placement: .primaryAction) {
                let unused = all.filter { !$0.inLog }
                Button("Remove Unused", systemImage: "trash") { store.sweepDeletable(unused.map(\.model)) }
                    .disabled(unused.isEmpty)
                    .help("Remove price rows for models that never appear in the log")
            }
        }
        .onAppear { store.refresh() }
    }

    private func table(_ rows: [PricingRowData]) -> some View {
        Table(rows, sortOrder: $sort) {
            TableColumn("Model", value: \.model) { row in
                HStack(spacing: Space.xs) {
                    if row.needsPrice {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .help("Used in the log but not priced")
                    }
                    Text(row.model).font(.identifier).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 260)
            TableColumn("Input $/M", value: \.inputRate) { row in
                RateField(model: row.model, field: "input", value: row.price.input, store: store, editor: editor)
            }
            .width(min: 62, ideal: 84)
            TableColumn("Output $/M", value: \.outputRate) { row in
                RateField(model: row.model, field: "output", value: row.price.output, store: store, editor: editor)
            }
            .width(min: 62, ideal: 84)
            TableColumn("Cached $/M", value: \.cachedRate) { row in
                RateField(model: row.model, field: "cached", value: row.price.cached, store: store, editor: editor)
            }
            .width(min: 62, ideal: 84)
            TableColumn("Peak", value: \.peakRank) { row in
                Toggle("Peak pricing", isOn: Binding(
                    get: { row.peak },
                    set: { on in store.togglePeak(row.model, on: on) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Peak pricing for \(row.model)")
            }
            .width(min: 44, ideal: 52)
            TableColumn("Peak In") { row in
                PeakField(row: row, field: "input_peak", value: row.price.inputPeak ?? 0, store: store, editor: editor)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Peak Out") { row in
                PeakField(row: row, field: "output_peak", value: row.price.outputPeak ?? 0, store: store, editor: editor)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Peak Cache") { row in
                PeakField(row: row, field: "cached_peak", value: row.price.cachedPeak ?? 0, store: store, editor: editor)
            }
            .width(min: 64, ideal: 80)
            TableColumn("Peak Hours") { row in
                PeakHours(row: row, store: store, editor: editor)
            }
            .width(min: 90, ideal: 120)
            TableColumn("") { row in
                HStack(spacing: Space.xs) {
                    Button {
                        fetch(row.model)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderless)
                    .disabled(editor.fetching.contains(row.model) || editor.fetchingAll)
                    .help("Fetch price from models.dev")
                    if !row.inLog {
                        Button(role: .destructive) {
                            store.removeModel(row.model)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove price for \(row.model)")
                    }
                }
            }
            .width(56)
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView.search(text: app.search) }
        }
    }

    private var saveFailure: String? {
        if case .failed(let message) = store.saver.status { return message }
        return nil
    }

    private func fetch(_ model: String) {
        guard !editor.fetching.contains(model), !editor.fetchingAll else { return }
        editor.fetching.insert(model)
        Task {
            _ = await store.fetchPrice(model)
            editor.fetching.remove(model)
        }
    }

    private func fetchAll(_ all: [PricingRowData]) {
        let models = all.map(\.model)
        guard !models.isEmpty, !editor.fetchingAll else { return }
        editor.fetchingAll = true
        Task {
            await store.fetchAll(models)
            editor.fetchingAll = false
        }
    }
}

private struct RateField: View {
    let model: String
    let field: String
    let value: Double
    let store: PricingStore
    let editor: PricingEditor
    var alignment: TextAlignment = .leading

    var body: some View {
        let key = "\(model):\(field)"
        TextField(field, text: Binding(
            get: { editor.draft(key, PanelFormats.rate(value)) },
            set: { text in
                editor.set(key, text) { committed in
                    store.setRate(model, field: field,
                                  value: Double(committed.trimmingCharacters(in: .whitespaces)) ?? 0)
                }
            }))
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .font(.figure)
            .help("\(field.replacingOccurrences(of: "_", with: " ")) price per 1M tokens for \(model)")
    }
}

private struct PeakField: View {
    let row: PricingRowData
    let field: String
    let value: Double
    let store: PricingStore
    let editor: PricingEditor

    var body: some View {
        if row.peak {
            RateField(model: row.model, field: field, value: value, store: store, editor: editor)
        } else {
            Text("—").font(.figure).foregroundStyle(.tertiary)
        }
    }
}

private struct PeakHours: View {
    let row: PricingRowData
    let store: PricingStore
    let editor: PricingEditor

    var body: some View {
        if row.peak {
            let key = "\(row.model):hours"
            TextField("Hours", text: Binding(
                get: { editor.draft(key, Self.format(row.price.peakWindows ?? [])) },
                set: { text in
                    editor.set(key, text) { committed in
                        store.setWindows(row.model, windows: Self.parse(committed))
                    }
                }), prompt: Text("1-4, 6-10"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.figure)
                .help("UTC hour windows when peak rates apply, e.g. 1-4, 6-10")
        } else {
            Text("—").font(.figure).foregroundStyle(.tertiary)
        }
    }

    static func format(_ windows: [[Int]]) -> String {
        windows.compactMap { $0.count > 1 ? "\($0[0])-\($0[1])" : nil }.joined(separator: ", ")
    }

    static func parse(_ text: String) -> [[Int]] {
        text.split(separator: ",").compactMap { part in
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 2 else { return nil }
            return bounds.map { min(23, max(0, $0)) }
        }
    }
}
