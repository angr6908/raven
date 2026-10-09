import Charts
import SwiftUI

enum UsageRange: String, CaseIterable, Identifiable {
    case day, week, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24 Hours"
        case .week: "7 Days"
        case .all: "All Time"
        }
    }

    var cutoffMs: Double? {
        switch self {
        case .day: (Date.now.timeIntervalSince1970 - 86_400) * 1000
        case .week: (Date.now.timeIntervalSince1970 - 7 * 86_400) * 1000
        case .all: nil
        }
    }
}

struct OverviewSnapshot {
    var totals = UsageTotals()
    var series: [SeriesPoint] = []
    var top: [UsageModelAgg] = []
    var count = 0

    init() {}

    init(records: [UsageRecord], range: UsageRange) {
        let scoped: [UsageRecord]
        if let cutoff = range.cutoffMs {
            scoped = records.filter { PanelAggregation.recordEndTimeMs($0) >= cutoff }
        } else {
            scoped = records
        }
        count = scoped.count
        totals = PanelAggregation.totals(scoped)
        series = PanelAggregation.hourly(scoped).compactMap { point in
            guard let date = PanelFormats.parseISO(point.timestamp) else { return nil }
            return SeriesPoint(date: date, input: point.inputTokens, output: point.outputTokens,
                               total: point.totalTokens, cost: point.cost, requests: point.requests)
        }
        top = Array(PanelAggregation.byModel(scoped).prefix(6))
    }
}

struct OverviewPage: View {
    private let usage = UsageStore.shared
    @AppStorage("overview.range") private var range = UsageRange.day
    @AppStorage("overview.topMetric") private var metric = TopMetric.tokens
    @State private var snapshot = OverviewSnapshot()
    @State private var selected: Date?
    @State private var loaded = false

    private struct TaskKey: Hashable {
        var revision: Int
        var range: UsageRange
    }

    enum TopMetric: String, CaseIterable, Identifiable {
        case tokens, cost, requests

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        Group {
            if usage.records.isEmpty {
                if loaded {
                    EmptyState(symbol: "chart.xyaxis.line", title: "No Usage Recorded Yet",
                               message: "Requests proxied through Raven will appear here.")
                } else {
                    LoadingState(message: "Loading usage…")
                }
            } else if snapshot.count == 0 {
                EmptyState(symbol: "clock.badge.questionmark", title: "Nothing in This Range",
                           message: "No requests in the last \(range.title.lowercased()). Try a wider range.")
            } else {
                Form {
                    if let error = usage.error {
                        Section { Notice(message: error) }
                    }
                    metrics
                    chartSection("Token Usage",
                                 legend: [("Input", Palette.input), ("Output", Palette.output)]) {
                        SeriesChart(kind: .tokens, points: snapshot.series, selected: $selected, height: 220)
                    }
                    chartSection("Cost", legend: []) {
                        SeriesChart(kind: .cost, points: snapshot.series, selected: $selected, height: 160)
                    }
                    chartSection("Requests", legend: []) {
                        SeriesChart(kind: .requests, points: snapshot.series, selected: $selected, height: 160)
                    }
                    topModels
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: TaskKey(revision: usage.revision, range: range)) {
            snapshot = OverviewSnapshot(records: usage.records, range: range)
            if !usage.records.isEmpty { loaded = true }
        }
        .task {
            usage.start()
            try? await Task.sleep(for: .seconds(2))
            loaded = true
        }
    }

    private var metrics: some View {
        let totals = snapshot.totals
        return Section {
            HStack(alignment: .top, spacing: Space.xl) {
                metric("Total Tokens", PanelFormats.formatTokens(totals.total),
                       "\(PanelFormats.formatTokens(totals.input)) in · \(PanelFormats.formatTokens(totals.output)) out")
                metric("Requests", String(totals.requests),
                       "\(totals.usedModels) model\(totals.usedModels == 1 ? "" : "s") used")
                metric("Estimated Cost", PanelFormats.formatCost(totals.cost),
                       "\(PanelFormats.formatPercent(totals.cacheRate)) cache hit rate")
                metric("Avg Duration", PanelFormats.formatDuration(totals.avgLatency),
                       "first token \(PanelFormats.formatDuration(totals.avgTTFT))")
            }
            .padding(.vertical, Space.xs)
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.metric).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartSection<Content: View>(_ title: String, legend: [(String, Color)],
                                             @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            HStack {
                Text(title)
                Spacer()
                ForEach(legend, id: \.0) { entry in
                    HStack(spacing: 4) {
                        StatusDot(tint: entry.1, size: 8)
                        Text(entry.0).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var topModels: some View {
        let ranked = snapshot.top.sorted { value($0) > value($1) }
        return Section {
            Picker("Rank by", selection: $metric) {
                ForEach(TopMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart(ranked, id: \.model) { agg in
                BarMark(x: .value(metric.title, value(agg)),
                        y: .value("Model", PanelAggregation.stripModelVendorAndProvider(agg.model)))
                    .foregroundStyle(Palette.input)
                    .annotation(position: .trailing) {
                        Text(label(value(agg))).font(.figureSmall).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().font(.identifierSmall) }
            }
            .frame(height: CGFloat(max(ranked.count, 1)) * 32 + 8)
        } header: {
            Text("Top Models")
        }
    }

    private func value(_ agg: UsageModelAgg) -> Double {
        switch metric {
        case .tokens: agg.total
        case .cost: agg.cost
        case .requests: Double(agg.requests)
        }
    }

    private func label(_ value: Double) -> String {
        switch metric {
        case .tokens: PanelFormats.formatTokens(value)
        case .cost: PanelFormats.formatCost(value)
        case .requests: String(Int(value))
        }
    }
}
