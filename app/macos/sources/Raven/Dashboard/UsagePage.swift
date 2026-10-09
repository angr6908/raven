import SwiftUI

nonisolated struct ModelUsageRow: Identifiable, Sendable {
    var id: String
    var title: String
    var provider: String
    var requests: Int
    var successRate: Double
    var input: Double
    var cacheRate: Double
    var output: Double
    var avgLatency: Double
    var avgTPS: Double
    var cost: Double

    init(_ agg: UsageModelAgg, short: String, provider: String) {
        id = agg.model
        title = short
        self.provider = provider
        requests = agg.requests
        successRate = agg.requests > 0 ? Double(agg.requests - agg.errors) / Double(agg.requests) : 0
        input = agg.input
        cacheRate = agg.input > 0 ? agg.cached / agg.input : 0
        output = agg.output
        avgLatency = agg.ok > 0 ? agg.latSum / Double(agg.ok) : 0
        avgTPS = agg.ok > 0 ? agg.tpsSum / Double(agg.ok) : 0
        cost = agg.cost
    }
}

nonisolated struct RequestRow: Identifiable, Sendable {
    var record: UsageRecord
    var title: String
    var provider: String
    var endMs: Double
    var input: Double
    var cached: Double
    var cacheRate: Double
    var output: Double
    var tps: Double

    var id: String { record.id }
    var status: Int { record.status }
    var cost: Double { record.costUsd }
    var effort: String { record.reasoningEffort ?? "" }
    var isError: Bool { record.status >= 400 }

    init(_ record: UsageRecord, short: String, provider: String) {
        self.record = record
        title = short
        self.provider = provider
        endMs = PanelAggregation.recordEndTimeMs(record)
        input = PanelAggregation.inputTotal(record)
        cached = PanelAggregation.cacheRead(record)
        cacheRate = input > 0 ? cached / input : 0
        output = Double(record.outputTokens)
        tps = PanelFormats.tps(outputTokens: record.outputTokens, latencyMs: record.latencyMs) ?? 0
    }
}

struct UsagePage: View {
    private let usage = UsageStore.shared
    private let routing = ProvidersPanelStore.shared

    enum Mode: String, CaseIterable, Identifiable {
        case requests, models

        var id: String { rawValue }
        var title: String { self == .models ? "By Model" : "Request Log" }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, errors

        var id: String { rawValue }
        var title: String { self == .all ? "All Requests" : "Errors Only" }
    }

    private struct TaskKey: Hashable {
        var revision: Int
        var providers: String
    }

    @Environment(AppModel.self) private var app
    @AppStorage("usage.view") private var mode = Mode.requests
    @State private var modelRows: [ModelUsageRow] = []
    @State private var requestRows: [RequestRow] = []
    @State private var totals = UsageTotals()
    @State private var modelSort = [KeyPathComparator(\ModelUsageRow.cost, order: .reverse)]
    @State private var filter = StatusFilter.all
    @State private var detail: RequestRow?
    @State private var confirmingClear = false
    @State private var notice: String?

    var body: some View {
        @Bindable var app = app
        Group {
            if usage.records.isEmpty {
                EmptyState(symbol: "tablecells", title: "No Usage Recorded Yet",
                           message: "Requests proxied through Raven will appear here.")
            } else {
                switch mode {
                case .models: modelsTable
                case .requests: requestsTable
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = usage.error ?? notice {
                Notice(message: message).padding(Space.md)
            }
        }
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if mode == .requests {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Show", selection: $filter) {
                        ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Filter the request log")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Log", systemImage: "trash") { confirmingClear = true }
                        .disabled(usage.records.isEmpty)
                        .help("Delete every recorded request")
                }
            }
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Filter by model")
        .sheet(item: $detail) { row in
            RequestDetailSheet(row: row)
        }
        .confirmationDialog("Clear the request log?", isPresented: $confirmingClear) {
            Button("Clear Log", role: .destructive) {
                Task { notice = await usage.clear() }
            }
        } message: {
            Text("This permanently deletes every recorded request from the proxy.")
        }
        .task(id: TaskKey(revision: usage.revision, providers: providerSignature)) {
            rebuild()
        }
        .onAppear {
            usage.start()
            routing.start()
        }
    }

    private var providerSignature: String {
        (routing.providers ?? [])
            .map { "\($0.name)|\($0.models.map { "\($0.name)|\($0.alias ?? "")" }.joined(separator: ","))" }
            .joined(separator: ";")
    }

    private func rebuild() {
        let index = PanelLogic.buildProviderModelIndex(routing.providers ?? [])
        let records = usage.records
        totals = PanelAggregation.totals(records)
        modelRows = PanelAggregation.byModel(records).map { agg in
            let display = PanelLogic.resolveModelDisplay(agg.model, index)
            return ModelUsageRow(agg, short: display.short, provider: display.provider ?? "")
        }
        requestRows = records.map { record in
            let display = PanelLogic.resolveModelDisplay(record.displayKey, index)
            return RequestRow(record, short: display.short, provider: display.provider ?? "")
        }
    }

    private var modelsTable: some View {
        let rows = modelRows.filter { matches($0.title) || matches($0.provider) }.sorted(using: modelSort)
        return Table(rows, sortOrder: $modelSort) {
            TableColumn("Model", value: \.title) { row in
                ModelCell(title: row.title, subtitle: row.provider)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Requests", value: \.requests) { row in
                Text(row.requests, format: .number).font(.figure)
            }
            .width(min: 64, ideal: 72)
            .alignment(.trailing)
            TableColumn("Success", value: \.successRate) { row in
                Text(PanelFormats.formatPercent(row.successRate))
                    .font(.figure)
                    .foregroundStyle(row.successRate < 0.9 ? Palette.bad : .primary)
            }
            .width(min: 56, ideal: 64)
            .alignment(.trailing)
            TableColumn("Input", value: \.input) { row in
                Text(PanelFormats.formatTokens(row.input)).font(.figureSmall)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
            TableColumn("Cache Hit", value: \.cacheRate) { row in
                Text(row.cacheRate > 0 ? PanelFormats.formatPercent(row.cacheRate) : "—").font(.figure)
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)
            TableColumn("Output", value: \.output) { row in
                Text(PanelFormats.formatTokens(row.output)).font(.figure)
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)
            TableColumn("Duration", value: \.avgLatency) { row in
                Text(row.avgLatency > 0 ? PanelFormats.formatDuration(row.avgLatency) : "—").font(.figureSmall)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
            TableColumn("TPS", value: \.avgTPS) { row in
                Text(row.avgTPS > 0 ? String(format: "%.1f", row.avgTPS) : "—").font(.figure)
            }
            .width(min: 48, ideal: 56)
            .alignment(.trailing)
            TableColumn("Cost", value: \.cost) { row in
                Text(PanelFormats.formatCost(row.cost)).font(.figure)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { totalsBar }
    }

    private var totalsBar: some View {
        HStack(spacing: Space.xl) {
            totalItem("Requests", String(totals.requests))
            totalItem("Input", PanelFormats.formatTokens(totals.input),
                      totals.cached > 0 ? "\(PanelFormats.formatTokens(totals.cached)) cached" : nil)
            totalItem("Output", PanelFormats.formatTokens(totals.output))
            totalItem("Avg Duration", totals.latCount > 0 ? PanelFormats.formatDuration(totals.avgLatency) : "—")
            totalItem("Cost", PanelFormats.formatCost(totals.cost))
            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    private func totalItem(_ label: String, _ value: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.callout.monospacedDigit().weight(.semibold))
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private var requestsTable: some View {
        let rows = requestRows
            .filter { filter == .all || $0.isError }
            .filter { matches($0.title) || matches($0.record.displayKey) }
        return Table(rows) {
            TableColumn("Time") { row in
                Text(Date(timeIntervalSince1970: row.endMs / 1000), format: .dateTime.month(.defaultDigits).day().hour().minute().second())
                    .font(.figure)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Model") { row in
                ModelCell(title: row.title, subtitle: row.provider)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Status") { row in
                Badge(text: String(row.status), tint: row.isError ? Palette.bad : Palette.good)
            }
            .width(min: 52, ideal: 60)
            TableColumn("Effort") { row in
                Text(row.effort.isEmpty ? "—" : row.effort).font(.subheadline)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Input") { row in
                Text(PanelFormats.formatTokens(row.input)).font(.figureSmall)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
            TableColumn("Output") { row in
                Text(PanelFormats.formatTokens(row.output)).font(.figure)
            }
            .width(min: 56, ideal: 66)
            .alignment(.trailing)
            TableColumn("Duration") { row in
                Text(PanelFormats.formatDuration(Double(row.record.latencyMs))).font(.figureSmall)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
            TableColumn("TPS") { row in
                Text(row.tps > 0 ? String(format: "%.1f", row.tps) : "—").font(.figure)
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)
            TableColumn("Cost") { row in
                Text(row.cost > 0 ? PanelFormats.formatCost(row.cost) : "—").font(.figure)
            }
            .width(min: 60, ideal: 72)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = requestRows.first(where: { $0.id == id }) {
                Button("Show Details", systemImage: "info.circle") { detail = row }
                if let requestId = row.record.requestId {
                    Button("Copy Request ID", systemImage: "document.on.document") { app.copy(requestId) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { detail = requestRows.first { $0.id == id } }
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView.search(text: app.search) }
        }
    }

    private func matches(_ text: String) -> Bool {
        let query = app.query
        return query.isEmpty || text.lowercased().contains(query)
    }
}

private struct ModelCell: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(title)
    }
}

private struct RequestDetailSheet: View {
    let row: RequestRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Badge(text: String(record.status), tint: row.isError ? Palette.bad : Palette.good)
                        Text(row.title).font(.headline).lineLimit(1)
                    }
                    if let error = record.error, !error.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section("Request") {
                    LabeledContent("Time", value: Date(timeIntervalSince1970: row.endMs / 1000)
                        .formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Model", value: record.model)
                    if !record.upstreamModel.isEmpty { LabeledContent("Upstream", value: record.upstreamModel) }
                    if !row.provider.isEmpty { LabeledContent("Provider", value: row.provider) }
                    LabeledContent("Account", value: record.account)
                    LabeledContent("Streamed", value: record.stream ? "Yes" : "No")
                    if let effort = record.reasoningEffort { LabeledContent("Effort", value: effort) }
                    if let reason = record.finishReason { LabeledContent("Finish", value: reason) }
                }
                Section("Tokens") {
                    LabeledContent("Input", value: PanelFormats.formatTokens(row.input))
                    LabeledContent("Cached", value: PanelFormats.formatTokens(row.cached))
                    LabeledContent("Cache hit", value: PanelFormats.formatPercent(row.cacheRate))
                    LabeledContent("Output", value: PanelFormats.formatTokens(row.output))
                    LabeledContent("Total", value: PanelFormats.formatTokens(record.totalTokens))
                }
                Section("Performance") {
                    LabeledContent("Duration", value: PanelFormats.formatDuration(Double(record.latencyMs)))
                    if record.ttftMs > 0 {
                        LabeledContent("First token", value: PanelFormats.formatDuration(Double(record.ttftMs)))
                    }
                    if row.tps > 0 { LabeledContent("Tokens / s", value: String(format: "%.1f", row.tps)) }
                    LabeledContent("Cost", value: PanelFormats.formatCost(record.costUsd))
                }
                if let requestId = record.requestId {
                    Section("Identifier") {
                        Text(requestId).font(.identifierSmall).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Request")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 480, height: 620)
    }

    private var record: UsageRecord { row.record }
}
