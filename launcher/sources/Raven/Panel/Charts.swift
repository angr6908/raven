import AppKit
import Charts
import SwiftUI

enum ChartPalette {
    static let input = gray(light: 0.52, dark: 0.66)
    static let output = gray(light: 0.32, dark: 0.88)
    static let total = gray(light: 0.62, dark: 0.56)
    static let cost = gray(light: 0.40, dark: 0.76)
    static let requests = gray(light: 0.46, dark: 0.70)
    static let cursor = Color(nsColor: .tertiaryLabelColor)

    private static func gray(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

@Observable
final class ChartState {
    var hoverIndex: Int?
}

enum ChartKind {
    case tokens
    case cost
    case requests

    func yLabel(_ value: Double) -> String {
        switch self {
        case .tokens: PanelFormats.formatTokens(value)
        case .cost: value >= 1 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
        case .requests: String(Int(value))
        }
    }

    func rows(_ point: UsagePoint) -> [(String, String)] {
        switch self {
        case .tokens:
            [("Input", PanelFormats.formatTokens(point.inputTokens)),
             ("Output", PanelFormats.formatTokens(point.outputTokens)),
             ("Total", PanelFormats.formatTokens(point.totalTokens))]
        case .cost:
            [("Cost", PanelFormats.formatCost(point.cost))]
        case .requests:
            [("Requests", String(point.requests))]
        }
    }

    func dot(_ index: Int) -> Color {
        switch self {
        case .tokens: [ChartPalette.output, ChartPalette.input, ChartPalette.total][safe: index] ?? .secondary
        case .cost: ChartPalette.cost
        case .requests: ChartPalette.requests
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct HourlyChart: View {
    var points: [UsagePoint]
    var kind: ChartKind
    var state: ChartState

    var body: some View {
        Chart {
            ForEach(points, id: \.timestamp) { point in
                marks(point)
            }
        }
        .chartLegend(.hidden)
        .chartForegroundStyleScale(["Input": ChartPalette.input, "Output": ChartPalette.output])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(kind.yLabel(number)).font(RavenFont.numeric(10))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel().font(RavenFont.numeric(10))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                state.hoverIndex = index(at: location, proxy: proxy, geo: geo)
                            case .ended:
                                state.hoverIndex = nil
                            }
                        }
                    if let index = state.hoverIndex, points.indices.contains(index) {
                        cursor(proxy: proxy, geo: geo, index: index)
                        tooltip(proxy: proxy, geo: geo, index: index)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func marks(_ point: UsagePoint) -> some ChartContent {
        switch kind {
        case .tokens:
            AreaMark(x: .value("Hour", point.label), y: .value("Tokens", point.inputTokens))
                .foregroundStyle(by: .value("Series", "Input"))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Hour", point.label), y: .value("Tokens", point.outputTokens))
                .foregroundStyle(by: .value("Series", "Output"))
                .interpolationMethod(.monotone)
        case .cost:
            BarMark(x: .value("Hour", point.label), y: .value("Cost", point.cost))
                .foregroundStyle(ChartPalette.cost)
        case .requests:
            BarMark(x: .value("Hour", point.label), y: .value("Requests", point.requests))
                .foregroundStyle(ChartPalette.requests)
        }
    }

    private func plot(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect? {
        guard let anchor = proxy.plotFrame else { return nil }
        return geo[anchor]
    }

    private func index(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard !points.isEmpty, let frame = plot(proxy, geo), frame.width > 0 else { return nil }
        let slot = frame.width / CGFloat(points.count)
        let raw = Int(((location.x - frame.minX) / slot).rounded(.down))
        return min(points.count - 1, max(0, raw))
    }

    @ViewBuilder
    private func cursor(proxy: ChartProxy, geo: GeometryProxy, index: Int) -> some View {
        if let frame = plot(proxy, geo), frame.width > 0 {
            let slot = frame.width / CGFloat(points.count)
            let x = frame.minX + slot * (CGFloat(index) + 0.5)
            Path { path in
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            .stroke(ChartPalette.cursor, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func tooltip(proxy: ChartProxy, geo: GeometryProxy, index: Int) -> some View {
        if let frame = plot(proxy, geo), frame.width > 0, points.indices.contains(index) {
            let point = points[index]
            let rows = kind.rows(point)
            let slot = frame.width / CGFloat(points.count)
            let anchorX = frame.minX + slot * (CGFloat(index) + 0.5)
            let width: CGFloat = 168
            let originX = min(max(frame.minX, anchorX + 10), max(frame.minX, frame.maxX - width))
            VStack(alignment: .leading, spacing: 3) {
                Text(point.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(kind.dot(row))
                        Text(rows[row].0)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(rows[row].1)
                            .font(RavenFont.numeric(10, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(8)
            .frame(width: width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1)
            }
            .shadow(radius: 8, y: 2)
            .offset(x: originX, y: frame.minY + 8)
        }
    }
}
