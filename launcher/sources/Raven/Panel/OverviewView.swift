import SwiftUI

private let overviewPageState = OverviewPageState()

@Observable
final class OverviewPageState {
    var renderedOnce = false
    var chart = ChartState()
    var totals = UsageTotals()
    var points: [UsagePoint] = []
    private var aggregatedRevision = -1

    func update(records: [UsageRecord], revision: Int) {
        guard revision != aggregatedRevision else { return }
        aggregatedRevision = revision
        totals = PanelAggregation.totals(records)
        points = PanelAggregation.hourly(records)
    }
}

struct OverviewView: View {
    private let store = UsageStore.shared
    @Bindable private var page = overviewPageState

    var body: some View {
        PanelPage {
            PanelPageHeader(title: "Overview",
                            subtitle: store.error == nil && !store.records.isEmpty
                                ? "Last \(store.records.count) requests through the proxy"
                                : nil,
                            icon: "chart.bar.xaxis")
            PanelNotice(message: store.error)

            if store.records.isEmpty {
                OverviewEmpty(renderedOnce: page.renderedOnce)
                    .onAppear { page.renderedOnce = page.renderedOnce || !store.records.isEmpty }
                    .onChange(of: store.records.count) { _, count in
                        if count > 0 { page.renderedOnce = true }
                    }
            } else {
                OverviewStats(totals: page.totals)
                OverviewTokenChart(points: page.points, state: page.chart)
                HStack(alignment: .top, spacing: Metrics.spacing4) {
                    OverviewCostChart(points: page.points, state: page.chart)
                    OverviewRequestChart(points: page.points, state: page.chart)
                }
            }
        }
        .task(id: store.revision) {
            page.update(records: store.records, revision: store.revision)
        }
        .onAppear {
            page.renderedOnce = page.renderedOnce || !store.records.isEmpty
            store.start()
        }
        .onChange(of: store.records.count) { _, count in
            if count > 0 { page.renderedOnce = true }
        }
    }
}

private struct OverviewEmpty: View {
    var renderedOnce: Bool

    var body: some View {
        if !renderedOnce {
            RavenLoader(message: "Loading usage…")
                .frame(height: 320)
        } else {
            EmptyState(symbol: "chart.xyaxis.line",
                       title: "No usage recorded yet",
                       message: "Requests proxied through Raven will appear here.")
                .frame(height: 320)
        }
    }
}

private struct OverviewStats: View {
    let totals: UsageTotals

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            StatTile(icon: "chart.bar.fill",
                     label: "Total tokens",
                     value: PanelFormats.formatTokens(totals.total),
                     sub: "\(PanelFormats.formatTokens(totals.input)) in · \(PanelFormats.formatTokens(totals.output)) out",
                     badge: nil,
                     tint: .blue)
            StatTile(icon: "bolt.fill",
                     label: "Requests",
                     value: String(totals.requests),
                     sub: "\(totals.usedModels) model\(totals.usedModels == 1 ? "" : "s") used",
                     badge: nil,
                     tint: .orange)
            StatTile(icon: "dollarsign.circle.fill",
                     label: "Est. cost",
                     value: PanelFormats.formatCost(totals.cost),
                     sub: nil,
                     badge: "\(PanelFormats.formatPercent(totals.cacheRate)) cache hit rate",
                     tint: .green)
            StatTile(icon: "gauge.with.dots.needle.67percent",
                     label: "Duration",
                     value: PanelFormats.formatDuration(totals.avgLatency),
                     sub: "avg TTFT \(PanelFormats.formatDuration(totals.avgTTFT))",
                     badge: nil,
                     tint: .purple)
        }
    }
}

private struct OverviewTokenChart: View {
    let points: [UsagePoint]
    let state: ChartState

    var body: some View {
        ChartCard(title: "Token usage",
                  subtitle: "Input vs output tokens per hour",
                  legend: [(ChartPalette.output, "Output"), (ChartPalette.input, "Input")],
                  chartHeight: 256) {
            HourlyChart(points: points, kind: .tokens, state: state)
        }
    }
}

private struct OverviewCostChart: View {
    let points: [UsagePoint]
    let state: ChartState

    var body: some View {
        ChartCard(title: "Cost over time",
                  subtitle: "Estimated spend per hour (USD)",
                  chartHeight: 208) {
            HourlyChart(points: points, kind: .cost, state: state)
        }
    }
}

private struct OverviewRequestChart: View {
    let points: [UsagePoint]
    let state: ChartState

    var body: some View {
        ChartCard(title: "Requests per hour",
                  subtitle: "Successful + failed calls",
                  chartHeight: 208) {
            HourlyChart(points: points, kind: .requests, state: state)
        }
    }
}
