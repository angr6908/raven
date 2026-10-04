import Charts
import SwiftUI

struct SeriesPoint: Identifiable {
    var date: Date
    var input: Double
    var output: Double
    var total: Double
    var cost: Double
    var requests: Int

    var id: Date { date }
}

enum SeriesKind {
    case tokens, cost, requests

    func axisLabel(_ value: Double) -> String {
        switch self {
        case .tokens: PanelFormats.formatTokens(value)
        case .cost: value >= 1 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
        case .requests: String(Int(value))
        }
    }

    func rows(_ point: SeriesPoint) -> [(String, String, Color)] {
        switch self {
        case .tokens:
            [("Input", PanelFormats.formatTokens(point.input), Palette.input),
             ("Output", PanelFormats.formatTokens(point.output), Palette.output),
             ("Total", PanelFormats.formatTokens(point.total), .secondary)]
        case .cost:
            [("Cost", PanelFormats.formatCost(point.cost), Palette.cost)]
        case .requests:
            [("Requests", String(point.requests), Palette.requests)]
        }
    }
}

struct SeriesChart: View {
    let kind: SeriesKind
    let points: [SeriesPoint]
    @Binding var selected: Date?
    var height: CGFloat = 200

    private var highlighted: SeriesPoint? {
        guard let selected else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                marks(point)
            }
            if let point = highlighted {
                RuleMark(x: .value("Selected", point.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(point)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(kind.axisLabel(number)).font(.figureSmall)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour(), centered: false)
                    .font(.figureSmall)
            }
        }
        .frame(height: height)
    }

    @ChartContentBuilder
    private func marks(_ point: SeriesPoint) -> some ChartContent {
        switch kind {
        case .tokens:
            AreaMark(x: .value("Hour", point.date), y: .value("Tokens", point.input),
                     series: .value("Series", "Input"), stacking: .unstacked)
                .foregroundStyle(Palette.input.opacity(0.28))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Hour", point.date), y: .value("Tokens", point.input),
                     series: .value("Series", "Input"))
                .foregroundStyle(Palette.input)
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Hour", point.date), y: .value("Tokens", point.output),
                     series: .value("Series", "Output"), stacking: .unstacked)
                .foregroundStyle(Palette.output.opacity(0.28))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Hour", point.date), y: .value("Tokens", point.output),
                     series: .value("Series", "Output"))
                .foregroundStyle(Palette.output)
                .interpolationMethod(.monotone)
        case .cost:
            BarMark(x: .value("Hour", point.date, unit: .hour), y: .value("Cost", point.cost))
                .foregroundStyle(Palette.cost)
        case .requests:
            BarMark(x: .value("Hour", point.date, unit: .hour), y: .value("Requests", point.requests))
                .foregroundStyle(Palette.requests)
        }
    }

    private func tooltip(_ point: SeriesPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.subheadline.weight(.semibold))
            ForEach(kind.rows(point), id: \.0) { row in
                HStack(spacing: 5) {
                    StatusDot(tint: row.2, size: 6)
                    Text(row.0).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(row.1).font(.subheadline.monospacedDigit().weight(.medium))
                }
            }
        }
        .padding(Space.sm)
        .frame(width: 150)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.control))
    }
}
