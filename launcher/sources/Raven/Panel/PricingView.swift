import SwiftUI

private let pricingPageState = PricingPageState()

@Observable
final class PricingPageState {
    enum SortKey: String, CaseIterable {
        case model, input, output, cached, peak
    }

    var expanded: Set<String> = []
    var fetching: Set<String> = []
    var fetchingAll = false
    var fetchNote: String?
    var sortKey: SortKey = .model
    var sortAscending = true
    var drafts: [String: String] = [:]
    var pendingQuery = ""
    private var queryTasks: [String: Task<Void, Never>] = [:]

    func visibleRows(from rows: [PricingRowData]) -> [PricingRowData] {
        let query = pendingQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? rows : rows.filter { $0.model.lowercased().contains(query) }
        return filtered.sorted { a, b in
            if sortKey == .model {
                let order = a.model.localizedCompare(b.model)
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
            let left = sortValue(a)
            let right = sortValue(b)
            if left == right { return a.model.localizedCompare(b.model) == .orderedAscending }
            return sortAscending ? left < right : left > right
        }
    }

    private func sortValue(_ row: PricingRowData) -> Double {
        switch sortKey {
        case .peak: return PanelLogic.hasPeak(row.price) ? 1 : 0
        case .input: return row.price.input
        case .output: return row.price.output
        case .cached: return row.price.cached
        case .model: return 0
        }
    }

    func draft(_ key: String, _ fallback: String) -> String { drafts[key] ?? fallback }

    func setDraft(_ key: String, _ value: String, commit: @escaping (String) -> Void) {
        drafts[key] = value
        queryTasks[key]?.cancel()
        queryTasks[key] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit(value)
        }
    }

    func clearDrafts() {
        for task in queryTasks.values { task.cancel() }
        queryTasks.removeAll()
        drafts.removeAll()
    }
}

struct PricingView: View {
    private let store = PricingStore.shared
    @Bindable private var page = pricingPageState

    var body: some View {
        PanelPage {
            PanelPageHeader(title: "Pricing",
                            subtitle: pricingSummary,
                            icon: "tag")
            PanelNotice(message: store.error ?? saveFailure)
            if store.loading {
                RavenLoader(message: "Loading prices…").frame(height: 160)
            } else {
                PricingCard(store: store, page: page)
                PricingFooter(store: store, page: page)
            }
        }
        .onAppear { store.refresh() }
    }

    private var pricingSummary: String? {
        guard !store.loading else { return nil }
        let all = store.rows()
        guard !all.isEmpty else { return nil }
        let unpriced = all.filter { !$0.priced && $0.inLog }.count
        return unpriced > 0
            ? "\(all.count) models · \(unpriced) in use without prices"
            : "\(all.count) models · all used models priced"
    }

    private var saveFailure: String? {
        if case .failed(let message) = store.saver.status { return message }
        return nil
    }
}

private struct PricingCard: View {
    let store: PricingStore
    @Bindable var page: PricingPageState

    private let chevronWidth: CGFloat = 18
    private let rateWidth: CGFloat = 74
    private let peakWidth: CGFloat = 54
    private let fetchWidth: CGFloat = 26
    private let trashWidth: CGFloat = 26

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Model prices").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    TextField("Filter models…", text: Binding(
                        get: { page.pendingQuery },
                        set: { page.pendingQuery = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 200)
                }
                PricingColumnHeader(store: store, page: page,
                                    chevronWidth: chevronWidth, rateWidth: rateWidth,
                                    peakWidth: peakWidth, fetchWidth: fetchWidth,
                                    trashWidth: trashWidth)
                Divider()
                if page.visibleRows(from: store.rows()).isEmpty {
                    Text(store.rows().isEmpty ? "No prices yet." : "No results.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    PricingRowsList(store: store, page: page,
                                    chevronWidth: chevronWidth, rateWidth: rateWidth,
                                    peakWidth: peakWidth, fetchWidth: fetchWidth,
                                    trashWidth: trashWidth)
                }
            }
        }
    }
}

private struct PricingColumnHeader: View {
    let store: PricingStore
    @Bindable var page: PricingPageState
    var chevronWidth: CGFloat
    var rateWidth: CGFloat
    var peakWidth: CGFloat
    var fetchWidth: CGFloat
    var trashWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: chevronWidth)
            sortButton("Model", key: .model, flexible: true)
            sortButton("Input $/M", key: .input, width: rateWidth)
            sortButton("Output $/M", key: .output, width: rateWidth)
            sortButton("Cached $/M", key: .cached, width: rateWidth)
            sortButton("Peak", key: .peak, width: peakWidth)
            PricingFetchAllButton(store: store, page: page)
                .frame(width: fetchWidth)
            if store.rows().contains(where: { !$0.inLog }) {
                PricingSweepButton(store: store, page: page)
                    .frame(width: trashWidth)
            } else {
                Color.clear.frame(width: trashWidth)
            }
        }
    }

    private func sortButton(_ text: String, key: PricingPageState.SortKey,
                            width: CGFloat = 0, flexible: Bool = false) -> some View {
        Button {
            if page.sortKey == key {
                page.sortAscending.toggle()
            } else {
                page.sortKey = key
                page.sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: page.sortKey == key
                      ? (page.sortAscending ? "chevron.up" : "chevron.down")
                      : "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: flexible ? nil : width, alignment: flexible ? .leading : .trailing)
            .frame(maxWidth: flexible ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(text)")
    }
}

private struct PricingFetchAllButton: View {
    let store: PricingStore
    @Bindable var page: PricingPageState

    var body: some View {
        Button {
            fetchAll()
        } label: {
            Image(systemName: "cloud.download")
                .font(.system(size: 12))
                .foregroundStyle(page.fetchingAll ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(page.fetchingAll)
        .help("Fetch all prices from models.dev")
    }

    private func fetchAll() {
        let models = store.rows().map(\.model)
        guard !models.isEmpty, !page.fetchingAll else { return }
        page.fetchingAll = true
        page.fetchNote = nil
        Task {
            let outcome = await store.fetchAll(models)
            page.fetchingAll = false
            var parts = ["\(outcome.priced) priced"]
            if outcome.empty > 0 { parts.append("\(outcome.empty) not on models.dev") }
            if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
            page.fetchNote = "Fetched \(models.count) models from models.dev — \(parts.joined(separator: ", "))."
        }
    }
}

private struct PricingSweepButton: View {
    let store: PricingStore
    @Bindable var page: PricingPageState

    var body: some View {
        Button {
            store.sweepDeletable(store.rows().filter { !$0.inLog }.map(\.model))
            page.expanded.removeAll()
        } label: {
            Image(systemName: "broom")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove all unused price rows")
    }
}

private struct PricingRowsList: View {
    let store: PricingStore
    @Bindable var page: PricingPageState
    var chevronWidth: CGFloat
    var rateWidth: CGFloat
    var peakWidth: CGFloat
    var fetchWidth: CGFloat
    var trashWidth: CGFloat

    var body: some View {
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(page.visibleRows(from: store.rows()), id: \.model) { row in
                    PricingRow(store: store, page: page, row: row,
                               chevronWidth: chevronWidth, rateWidth: rateWidth,
                               peakWidth: peakWidth, fetchWidth: fetchWidth,
                               trashWidth: trashWidth)
                    if row.peak, page.expanded.contains(row.model) {
                        PricingPeakRow(store: store, page: page, row: row,
                                       rateWidth: rateWidth, peakWidth: peakWidth,
                                       fetchWidth: fetchWidth, trashWidth: trashWidth)
                    }
                }
            }
        }
        .frame(maxHeight: 520)
    }
}

private struct PricingRow: View {
    let store: PricingStore
    @Bindable var page: PricingPageState
    let row: PricingRowData
    var chevronWidth: CGFloat
    var rateWidth: CGFloat
    var peakWidth: CGFloat
    var fetchWidth: CGFloat
    var trashWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            PricingRowChevron(page: page, row: row)
                .frame(width: chevronWidth)

            Text(row.model)
                .font(RavenFont.mono(11))
                .foregroundStyle(!row.priced && row.inLog ? Color.orange : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.model)

            rateField(row, field: "input")
            rateField(row, field: "output")
            rateField(row, field: "cached")

            peakCell(row)
            fetchCell(row)

            if row.inLog {
                Color.clear.frame(width: trashWidth)
            } else {
                Button {
                    page.expanded.remove(row.model)
                    store.removeModel(row.model)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .frame(width: trashWidth)
                .help("Remove price for \(row.model)")
            }
        }
    }

    private func rateField(_ row: PricingRowData, field: String) -> some View {
        let key = "\(row.model):\(field)"
        let value = rateValue(row.price, field: field)
        return TextField("", text: Binding(
            get: { page.draft(key, PanelFormats.rate(value)) },
            set: { text in
                page.setDraft(key, text) { committed in
                    store.setRate(row.model, field: field, value: Double(committed.trimmingCharacters(in: .whitespaces)) ?? 0)
                }
            }))
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .font(RavenFont.mono(11))
        .frame(width: rateWidth)
        .help("\(field) price per 1M tokens for \(row.model)")
    }

    private func rateValue(_ price: ModelPrice, field: String) -> Double {
        switch field {
        case "input": price.input
        case "output": price.output
        case "cached": price.cached
        case "input_peak": price.inputPeak ?? 0
        case "output_peak": price.outputPeak ?? 0
        default: price.cachedPeak ?? 0
        }
    }

    private func peakCell(_ row: PricingRowData) -> some View {
        HStack {
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { row.peak },
                set: { on in
                    store.togglePeak(row.model, on: on)
                    if on { page.expanded.insert(row.model) } else { page.expanded.remove(row.model) }
                }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Peak pricing \(row.peak ? "on" : "off") for \(row.model)")
        }
        .frame(width: peakWidth)
    }

    private func fetchCell(_ row: PricingRowData) -> some View {
        let busy = page.fetching.contains(row.model) || page.fetchingAll
        return Button {
            startFetch(row.model)
        } label: {
            Image(systemName: "cloud.download")
                .font(.system(size: 12))
                .foregroundStyle(busy ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .frame(width: fetchWidth)
        .help("Fetch price from models.dev")
    }

    private func startFetch(_ model: String) {
        guard !page.fetching.contains(model), !page.fetchingAll else { return }
        page.fetching.insert(model)
        page.fetchNote = nil
        Task {
            _ = await store.fetchPrice(model)
            page.fetching.remove(model)
        }
    }
}

private struct PricingRowChevron: View {
    @Bindable var page: PricingPageState
    let row: PricingRowData

    var body: some View {
        if row.peak {
            Button {
                if page.expanded.contains(row.model) {
                    page.expanded.remove(row.model)
                } else {
                    page.expanded.insert(row.model)
                }
            } label: {
                Image(systemName: page.expanded.contains(row.model) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("\(page.expanded.contains(row.model) ? "Hide" : "Edit") peak pricing for \(row.model)")
        }
    }
}

private struct PricingPeakRow: View {
    let store: PricingStore
    @Bindable var page: PricingPageState
    let row: PricingRowData
    var rateWidth: CGFloat
    var peakWidth: CGFloat
    var fetchWidth: CGFloat
    var trashWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 20)
            Text("Peak windows UTC")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            HStack(spacing: 3) {
                ForEach(Array((row.price.peakWindows ?? []).enumerated()), id: \.offset) { index, window in
                    let start = window.count > 0 ? window[0] : 1
                    let end = window.count > 1 ? window[1] : 4
                    hourField(row, index: index, pos: 0, value: start)
                    Text("–").font(.system(size: 10)).foregroundStyle(.secondary)
                    hourField(row, index: index, pos: 1, value: end)
                    Button {
                        store.removeWindow(row.model, index: index)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove peak window \(index + 1) for \(row.model)")
                }
                Button {
                    store.addWindow(row.model)
                } label: {
                    Image(systemName: "plus").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add peak window for \(row.model)")
            }
            Spacer(minLength: 8)
            rateField(row, field: "input_peak")
            rateField(row, field: "output_peak")
            rateField(row, field: "cached_peak")
            Color.clear.frame(width: peakWidth)
            Color.clear.frame(width: fetchWidth)
            Color.clear.frame(width: trashWidth)
        }
    }

    private func rateField(_ row: PricingRowData, field: String) -> some View {
        let key = "\(row.model):\(field)"
        let value = rateValue(row.price, field: field)
        return TextField("", text: Binding(
            get: { page.draft(key, PanelFormats.rate(value)) },
            set: { text in
                page.setDraft(key, text) { committed in
                    store.setRate(row.model, field: field, value: Double(committed.trimmingCharacters(in: .whitespaces)) ?? 0)
                }
            }))
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .font(RavenFont.mono(11))
        .frame(width: rateWidth)
        .help("\(field) price per 1M tokens for \(row.model)")
    }

    private func rateValue(_ price: ModelPrice, field: String) -> Double {
        switch field {
        case "input_peak": price.inputPeak ?? 0
        case "output_peak": price.outputPeak ?? 0
        default: price.cachedPeak ?? 0
        }
    }

    private func hourField(_ row: PricingRowData, index: Int, pos: Int, value: Int) -> some View {
        let key = "\(row.model):h\(index):\(pos)"
        return TextField("", text: Binding(
            get: { page.draft(key, String(value)) },
            set: { text in
                page.setDraft(key, text) { committed in
                    let parsed = Double(committed.trimmingCharacters(in: .whitespaces)).map { Int($0) }
                    store.editWindow(row.model, index: index, pos: pos,
                                     value: parsed.map { min(23, max(0, $0)) })
                }
            }))
        .textFieldStyle(.plain)
        .multilineTextAlignment(.center)
        .font(RavenFont.mono(11))
        .frame(width: 30)
        .help("Peak \(pos == 0 ? "start" : "end") hour \(index + 1) for \(row.model)")
    }
}

private struct PricingFooter: View {
    let store: PricingStore
    @Bindable var page: PricingPageState

    var body: some View {
        if let note = page.fetchNote {
            footerText(note)
        } else {
            switch store.saver.status {
            case .saving:
                footerText("Saving…")
            case .saved:
                footerText("Saved — costs updated.")
            case .failed:
                footerText("Save failed.")
            case .idle:
                let unpriced = store.rows().filter { !$0.priced && $0.inLog }.count
                footerText(unpriced > 0
                           ? "\(unpriced) model\(unpriced == 1 ? "" : "s") in use without prices"
                           : "all used models priced")
            }
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
