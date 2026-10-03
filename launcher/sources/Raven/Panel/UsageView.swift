import SwiftUI

private let usagePageState = UsagePageState()

@Observable
final class UsagePageState {
    var modelTable = DataTableState()
    var requestTable = DataTableState()
    var notice: String?
    var isClearing = false
    var providerIndex: PanelLogic.ProviderModelIndex = [:]
    private var signature = "\u{0}"

    func refreshProviderIndex() {
        let panel = ProvidersPanelStore.shared
        guard let providers = panel.providers else {
            signature = "\u{1}"
            providerIndex = [:]
            return
        }
        let next = providers.map { "\($0.name)|\($0.models.map { "\($0.name)|\($0.alias ?? "")" }.joined(separator: ","))" }
            .joined(separator: ";")
        guard next != signature else { return }
        signature = next
        providerIndex = PanelLogic.buildProviderModelIndex(providers)
    }

    func shortModel(_ key: String) -> String {
        PanelLogic.resolveModelDisplay(key, providerIndex).short
    }

    func providerLabel(_ key: String) -> String? {
        PanelLogic.resolveModelDisplay(key, providerIndex).provider
    }
}

struct UsageView: View {
    private let store = UsageStore.shared
    @Bindable private var page = usagePageState

    var body: some View {
        PanelPage {
            PanelPageHeader(title: "Usage",
                            subtitle: store.records.isEmpty
                                ? nil
                                : "\(store.records.count) requests · \(PanelAggregation.byModel(store.records).count) models",
                            icon: "list.bullet.rectangle")
            PanelNotice(message: store.error ?? page.notice)

            PanelSection(title: "Usage by model") {
                modelTable
            }

            PanelSection(title: "Request log", trailing: requestControls) {
                requestTable
            }
        }
        .onAppear {
            page.refreshProviderIndex()
            store.start()
        }
    }

    private var requestControls: AnyView {
        AnyView(HStack(spacing: 8) {
            TextField("Filter by model…", text: $page.requestTable.query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 180)
            Button("Clear") { clearLog() }
                .controlSize(.small)
                .foregroundStyle(.red)
                .disabled(store.records.isEmpty || page.isClearing)
        })
    }

    private func clearLog() {
        page.isClearing = true
        page.notice = nil
        Task {
            let message = await store.clear()
            page.notice = message
            page.isClearing = false
        }
    }

    private var modelAggs: [UsageModelAgg] {
        PanelAggregation.byModel(store.records)
    }

    private var modelTable: some View {
        let aggs = modelAggs
        return DataTable(columns: modelColumns(aggs), rowCount: aggs.count, state: page.modelTable,
                         footerCell: { column in modelFooterCell(aggs.count, column) },
                         pagination: true, hidePaginationOnSinglePage: true, maxHeight: 300,
                         filter: nil, rowMenu: nil)
    }

    private func modelColumns(_ aggs: [UsageModelAgg]) -> [DataColumn] {
        [
            DataColumn(title: "Model", width: 180,
                       compare: columnByText { aggs[$0].model }) { row in
                AnyView(Text(page.shortModel(aggs[row].model))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(aggs[row].model))
            },
            DataColumn(title: "Provider", width: 110,
                       compare: columnByText { page.providerLabel(aggs[$0].model) ?? "" }) { row in
                AnyView(Text(page.providerLabel(aggs[row].model) ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1))
            },
            DataColumn(title: "Success", width: 64, alignsRight: true,
                       compare: columnByNumber { row in
                           let agg = aggs[row]
                           return agg.requests > 0 ? Double(agg.requests - agg.errors) / Double(agg.requests) : 0
                       }) { row in
                let agg = aggs[row]
                let rate = agg.requests > 0 ? Double(agg.requests - agg.errors) / Double(agg.requests) : 0
                return AnyView(Text(PanelFormats.formatPercent(rate))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Input", width: 120, alignsRight: true,
                       compare: columnByNumber { aggs[$0].input }) { row in
                let agg = aggs[row]
                return AnyView(Text(PanelFormats.formatTokens(agg.input)
                    + (agg.cached > 0 ? " · \(PanelFormats.formatTokens(agg.cached)) cached" : ""))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Cache hit", width: 72, alignsRight: true,
                       compare: columnByNumber { row in
                           let agg = aggs[row]
                           return agg.input > 0 ? agg.cached / agg.input : 0
                       }) { row in
                let agg = aggs[row]
                let rate = agg.input > 0 ? agg.cached / agg.input : 0
                return AnyView(Text(rate > 0 ? PanelFormats.formatPercent(rate) : "—")
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Output", width: 74, alignsRight: true,
                       compare: columnByNumber { aggs[$0].output }) { row in
                AnyView(Text(PanelFormats.formatTokens(aggs[row].output))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Avg duration", width: 118, alignsRight: true,
                       compare: columnByNumber { row in
                           let agg = aggs[row]
                           return agg.ok > 0 ? agg.latSum / Double(agg.ok) : 0
                       }) { row in
                let agg = aggs[row]
                guard agg.ok > 0 else { return AnyView(Text("—").font(RavenFont.numeric(11))) }
                let ttft = agg.ttftOk > 0 ? agg.ttftSum / Double(agg.ttftOk) : 0
                var text = PanelFormats.formatDuration(agg.latSum / Double(agg.ok))
                if ttft > 0 { text += " · \(PanelFormats.formatDuration(ttft)) first" }
                return AnyView(Text(text).font(RavenFont.numeric(11)).lineLimit(1))
            },
            DataColumn(title: "Avg TPS", width: 66, alignsRight: true,
                       compare: columnByNumber { row in
                           let agg = aggs[row]
                           return agg.ok > 0 ? agg.tpsSum / Double(agg.ok) : 0
                       }) { row in
                let agg = aggs[row]
                return AnyView(Text(agg.ok > 0 ? String(format: "%.1f", agg.tpsSum / Double(agg.ok)) : "—")
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Cost", width: 78, alignsRight: true,
                       compare: columnByNumber { aggs[$0].cost }) { row in
                AnyView(Text(PanelFormats.formatCost(aggs[row].cost))
                    .font(RavenFont.numeric(11)))
            },
        ]
    }

    private func modelFooterCell(_ count: Int, _ column: Int) -> AnyView {
        guard count > 0 else { return AnyView(EmptyView()) }
        let totals = PanelAggregation.totals(store.records)
        let ok = totals.latCount
        switch column {
        case 0:
            return AnyView(FooterStrong(text: "Total"))
        case 2:
            let text = totals.requests > 0 ? PanelFormats.formatPercent(Double(ok) / Double(totals.requests)) : "—"
            return AnyView(FooterStrong(text: text))
        case 3:
            return AnyView(FooterStrong(text: PanelFormats.formatTokens(totals.input),
                                        suffix: totals.cached > 0 ? "\(PanelFormats.formatTokens(totals.cached)) cached" : nil))
        case 4:
            let text = totals.input > 0 ? PanelFormats.formatPercent(totals.cacheRate) : "—"
            return AnyView(FooterStrong(text: text))
        case 5:
            return AnyView(FooterStrong(text: PanelFormats.formatTokens(totals.output)))
        case 6:
            let duration = ok > 0 ? PanelFormats.formatDuration(totals.latSum / Double(ok)) : "—"
            let ttft = totals.ttftCount > 0 ? PanelFormats.formatDuration(totals.avgTTFT) : nil
            return AnyView(FooterStrong(text: duration, suffix: ttft.map { "\($0) first" }))
        case 7:
            let text = ok > 0 ? String(format: "%.1f", totals.tpsSum / Double(ok)) : "—"
            return AnyView(FooterStrong(text: text))
        case 8:
            return AnyView(FooterStrong(text: PanelFormats.formatCost(totals.cost)))
        default:
            return AnyView(EmptyView())
        }
    }

    private var requestTable: some View {
        let records = store.records
        return DataTable(columns: requestColumns(records), rowCount: records.count, state: page.requestTable,
                         pagination: true, minHeight: 400, maxHeight: 640,
                         initialSort: (0, false),
                         filter: { row in records.indices.contains(row) ? records[row].displayKey : "" },
                         rowMenu: nil)
    }

    private func requestColumns(_ records: [UsageRecord]) -> [DataColumn] {
        [
            DataColumn(title: "Time", width: 108,
                       compare: columnByNumber { Double(PanelAggregation.recordEndTimeMs(records[$0])) }) { row in
                let endMs = PanelAggregation.recordEndTimeMs(records[row])
                return AnyView(Text(PanelFormats.formatDateTime(Date(timeIntervalSince1970: endMs / 1000)))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Model", width: 160,
                       compare: columnByText { records[$0].displayKey }) { row in
                AnyView(Text(page.shortModel(records[row].displayKey))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle))
            },
            DataColumn(title: "Provider", width: 96,
                       compare: columnByText { page.providerLabel(records[$0].displayKey) ?? "" }) { row in
                AnyView(Text(page.providerLabel(records[row].displayKey) ?? "—")
                    .font(.system(size: 11)))
            },
            DataColumn(title: "Status", width: 60,
                       compare: columnByNumber { Double(records[$0].status) }) { row in
                let status = records[row].status
                return AnyView(BadgeText(text: "\(status)", tint: status < 400 ? .green : .red))
            },
            DataColumn(title: "Effort", width: 66,
                       compare: columnByText { records[$0].reasoningEffort ?? "" }) { row in
                AnyView(Text(records[row].reasoningEffort ?? "—")
                    .font(.system(size: 11)))
            },
            DataColumn(title: "Input", width: 130, alignsRight: true,
                       compare: columnByNumber { PanelAggregation.inputTotal(records[$0]) }) { row in
                let r = records[row]
                let cached = PanelAggregation.cacheRead(r)
                return AnyView(Text(PanelFormats.formatTokens(PanelAggregation.inputTotal(r))
                    + (cached > 0 ? " · \(PanelFormats.formatTokens(cached)) cached" : ""))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Cache hit", width: 72, alignsRight: true,
                       compare: columnByNumber { row in
                           let r = records[row]
                           let total = PanelAggregation.inputTotal(r)
                           return total > 0 ? PanelAggregation.cacheRead(r) / total : 0
                       }) { row in
                let r = records[row]
                let total = PanelAggregation.inputTotal(r)
                let rate = total > 0 ? PanelAggregation.cacheRead(r) / total : 0
                return AnyView(Text(rate > 0 ? PanelFormats.formatPercent(rate) : "—")
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Output", width: 74, alignsRight: true,
                       compare: columnByNumber { Double(records[$0].outputTokens) }) { row in
                AnyView(Text(PanelFormats.formatTokens(records[row].outputTokens))
                    .font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Duration", width: 118, alignsRight: true,
                       compare: columnByNumber { Double(records[$0].latencyMs) }) { row in
                let r = records[row]
                var text = PanelFormats.formatDuration(Double(r.latencyMs))
                if r.ttftMs > 0 && r.ttftMs <= r.latencyMs {
                    text += " · \(PanelFormats.formatDuration(Double(r.ttftMs))) first"
                }
                return AnyView(Text(text).font(RavenFont.numeric(11)).lineLimit(1))
            },
            DataColumn(title: "TPS", width: 56, alignsRight: true,
                       compare: columnByNumber { row in
                           let r = records[row]
                           return PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs) ?? 0
                       }) { row in
                let r = records[row]
                guard let tps = PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs), tps > 0 else {
                    return AnyView(Text("—").font(RavenFont.numeric(11)))
                }
                return AnyView(Text(String(format: "%.1f", tps)).font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Cost", width: 76, alignsRight: true,
                       compare: columnByNumber { records[$0].costUsd }) { row in
                let cost = records[row].costUsd
                return AnyView(Text(cost > 0 ? PanelFormats.formatCost(cost) : "—")
                    .font(RavenFont.numeric(11)))
            },
        ]
    }
}
