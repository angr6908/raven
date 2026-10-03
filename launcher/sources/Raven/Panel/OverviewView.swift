import SwiftUI

private let overviewPageState = OverviewPageState()

@Observable
final class OverviewPageState {
    var renderedOnce = false
    var chart = ChartState()
}

struct OverviewView: View {
    private let store = UsageStore.shared
    @Bindable private var page = overviewPageState

    var body: some View {
        PanelPage {
            PanelNotice(message: store.error)

            if store.records.isEmpty {
                if !page.renderedOnce && store.error == nil {
                    RavenLoader(message: "Loading usage…")
                        .frame(height: 320)
                } else {
                    EmptyState(symbol: "chart.xyaxis.line",
                               title: "No usage recorded yet",
                               message: "Requests proxied through Raven will appear here.")
                        .frame(height: 320)
                }
            } else {
                stats
                tokenCard
                HStack(alignment: .top, spacing: Metrics.spacing4) {
                    costCard
                    requestCard
                }
            }
        }
        .onAppear {
            page.renderedOnce = page.renderedOnce || !store.records.isEmpty
            store.start()
        }
        .onChange(of: store.records.count) { _, count in
            if count > 0 { page.renderedOnce = true }
        }
    }

    private var totals: UsageTotals { PanelAggregation.totals(store.records) }
    private var points: [UsagePoint] { PanelAggregation.hourly(store.records) }

    private var stats: some View {
        let t = totals
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                         spacing: 12) {
            StatTile(icon: "chart.bar.fill",
                     label: "Total tokens",
                     value: PanelFormats.formatTokens(t.total),
                     sub: "\(PanelFormats.formatTokens(t.input)) in · \(PanelFormats.formatTokens(t.output)) out",
                     badge: nil)
            StatTile(icon: "bolt.fill",
                     label: "Requests",
                     value: String(t.requests),
                     sub: "\(t.usedModels) model\(t.usedModels == 1 ? "" : "s") used",
                     badge: nil)
            StatTile(icon: "dollarsign.circle.fill",
                     label: "Est. cost",
                     value: PanelFormats.formatCost(t.cost),
                     sub: nil,
                     badge: "\(PanelFormats.formatPercent(t.cacheRate)) cache hit rate")
            StatTile(icon: "gauge.with.dots.needle.67percent",
                     label: "Duration",
                     value: PanelFormats.formatDuration(t.avgLatency),
                     sub: "avg TTFT \(PanelFormats.formatDuration(t.avgTTFT))",
                     badge: nil)
        }
    }

    private var tokenCard: some View {
        ChartCard(title: "Token usage",
                  subtitle: "Input vs output tokens per hour",
                  legend: [(ChartPalette.output, "Output"), (ChartPalette.input, "Input")],
                  chartHeight: 256) {
            HourlyChart(points: points, kind: .tokens, state: page.chart)
        }
    }

    private var costCard: some View {
        ChartCard(title: "Cost over time",
                  subtitle: "Estimated spend per hour (USD)",
                  chartHeight: 208) {
            HourlyChart(points: points, kind: .cost, state: page.chart)
        }
    }

    private var requestCard: some View {
        ChartCard(title: "Requests per hour",
                  subtitle: "Successful + failed calls",
                  chartHeight: 208) {
            HourlyChart(points: points, kind: .requests, state: page.chart)
        }
    }
}
