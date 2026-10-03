import AppKit

nonisolated enum ChartPalette {
    private static func gray(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }
    }

    static let input = gray(light: 0.52, dark: 0.66)
    static let output = gray(light: 0.32, dark: 0.88)
    static let total = gray(light: 0.62, dark: 0.56)
    static let cost = gray(light: 0.40, dark: 0.76)
    static let requests = gray(light: 0.46, dark: 0.70)
    static let grid = NSColor.separatorColor
    static let cursor = NSColor.tertiaryLabelColor
}

nonisolated struct ChartHover {
    var index: Int
    var x: CGFloat
    var title: String
    var rows: [(String, String)]
}

@MainActor
class HourlyChartView: NSView {
    var points: [UsagePoint] = [] {
        didSet {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    let leftInset: CGFloat = 48
    let bottomInset: CGFloat = 22
    let topInset: CGFloat = 10

    private var trackingArea: NSTrackingArea?
    private(set) var hoverIndex: Int?

    var plotRect: NSRect {
        NSRect(x: leftInset,
               y: topInset,
               width: max(1, bounds.width - leftInset - 8),
               height: max(1, bounds.height - topInset - bottomInset))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let plot = plotRect
        let location = convert(event.locationInWindow, from: nil)
        guard !points.isEmpty, plot.width > 0 else { return }
        let slot = plot.width / CGFloat(points.count)
        let raw = Int(((location.x - plot.minX) / slot).rounded(.down))
        let index = min(points.count - 1, max(0, raw))
        guard index != hoverIndex else { return }
        hoverIndex = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverIndex != nil else { return }
        hoverIndex = nil
        needsDisplay = true
    }

    func hoverRows(_ point: UsagePoint) -> [(String, String)] { [] }

    func hoverTitle(_ point: UsagePoint) -> String { point.label }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlot()
        drawHover()
    }

    private func drawPlot() {
        let area = bounds.insetBy(dx: 0, dy: 0)
        let plot = NSRect(x: leftInset,
                          y: topInset,
                          width: max(1, area.width - leftInset - 8),
                          height: max(1, area.height - topInset - bottomInset))
        guard !points.isEmpty else { return }
        let maxValue = seriesMax
        guard maxValue > 0 else { return }

        let labelColor = NSColor.tertiaryLabelColor
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        let gridLines = 4
        for index in 0...gridLines {
            let fraction = CGFloat(index) / CGFloat(gridLines)
            let y = plot.maxY - plot.height * fraction
            let path = NSBezierPath()
            path.lineWidth = 0.5
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            ChartPalette.grid.withAlphaComponent(0.4).setStroke()
            path.stroke()
            drawText(yAxisLabel(maxValue * Double(fraction)),
                     at: NSPoint(x: plot.minX - 6, y: y),
                     font: tickFont,
                     color: labelColor,
                     alignRight: true)
        }

        let slot = plot.width / CGFloat(points.count)
        for (index, point) in points.enumerated() {
            let x = plot.minX + slot * (CGFloat(index) + 0.5)
            if index % tickStride == 0 {
                drawText(point.label,
                         at: NSPoint(x: x, y: plot.maxY + 4),
                         font: tickFont,
                         color: labelColor,
                         alignRight: false)
            }
            drawSeries(in: plot, slot: slot, index: index, x: x, point: point, maxValue: maxValue)
        }
    }

    private func drawHover() {
        guard let index = hoverIndex, points.indices.contains(index) else { return }
        let plot = plotRect
        guard plot.width > 0 else { return }
        let slot = plot.width / CGFloat(points.count)
        let x = plot.minX + slot * (CGFloat(index) + 0.5)

        let cursor = NSBezierPath()
        cursor.lineWidth = 1
        cursor.move(to: NSPoint(x: x, y: plot.minY))
        cursor.line(to: NSPoint(x: x, y: plot.maxY))
        ChartPalette.cursor.setStroke()
        cursor.stroke()

        let point = points[index]
        let title = hoverTitle(point)
        let rows = hoverRows(point)
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let rowFont = NSFont.systemFont(ofSize: 10)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

        var lines: [(NSAttributedString, CGFloat)] = []
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: NSColor.labelColor,
        ]
        lines.append((NSAttributedString(string: title, attributes: titleAttributes), 14))

        let rowLabelWidth = rows.reduce(CGFloat(0)) { width, row in
            max(width, ("\(row.0)  " as NSString).size(withAttributes: [.font: rowFont]).width)
        }
        let dotAttachment = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .regular))

        for (rowIndex, (label, value)) in rows.enumerated() {
            let text = NSMutableAttributedString(string: "\(label)  ", attributes: [
                .font: rowFont, .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let padding = rowLabelWidth - ("\(label)  " as NSString).size(withAttributes: [.font: rowFont]).width
            if padding > 0 {
                text.append(NSAttributedString(string: String(repeating: " ", count: Int(padding / 3)),
                                               attributes: [.font: rowFont]))
            }
            text.append(NSAttributedString(string: value, attributes: [
                .font: valueFont, .foregroundColor: NSColor.labelColor,
            ]))
            if let dotAttachment {
                let dot = NSTextAttachment()
                dot.image = dotAttachment
                dot.bounds = NSRect(x: 0, y: -1, width: 7, height: 7)
                let rowColor = rowIndex < seriesColors.count ? seriesColors[rowIndex] : NSColor.labelColor
                let attributedDot = NSMutableAttributedString(attachment: dot)
                attributedDot.addAttribute(.foregroundColor, value: rowColor, range: NSRange(location: 0, length: attributedDot.length))
                text.insert(attributedDot, at: 0)
                text.insert(NSAttributedString(string: " ", attributes: [.font: rowFont]), at: 1)
            }
            lines.append((text, 14))
        }

        let width = lines.reduce(CGFloat(0)) { max($0, $1.0.size().width) } + 16
        let height = lines.reduce(CGFloat(0)) { $0 + $1.1 } + 10

        var originX = x + 10
        if originX + width > plot.maxX { originX = x - width - 10 }
        originX = max(plot.minX, originX)
        var originY = plot.minY + 6
        if originY + height > plot.maxY { originY = plot.maxY - height }

        let box = NSRect(x: originX, y: originY, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.quaternaryLabelColor.setStroke()
        let border = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()

        var cursorY = box.minY + 5
        for (text, lineHeight) in lines {
            text.draw(at: NSPoint(x: box.minX + 8, y: cursorY))
            cursorY += lineHeight
        }
    }

    var seriesColors: [NSColor] { [] }

    var tickStride: Int {
        max(1, (points.count + 7) / 8)
    }

    var seriesMax: Double {
        points.map { seriesValue($0) }.max() ?? 0
    }

    func seriesValue(_ point: UsagePoint) -> Double { 0 }

    func drawSeries(in plot: NSRect, slot: CGFloat, index: Int, x: CGFloat,
                    point: UsagePoint, maxValue: Double) {}

    func bar(in plot: NSRect, x: CGFloat, slot: CGFloat, value: Double,
             maxValue: Double, color: NSColor, widthFactor: CGFloat = 0.62) {
        guard value > 0 else { return }
        let rawHeight = plot.height * CGFloat(value / maxValue)
        let height = max(rawHeight, 2)
        let rect = NSRect(x: x - slot * widthFactor / 2,
                          y: plot.maxY - height,
                          width: slot * widthFactor,
                          height: height)
        color.setFill()
        let radius = min(3, rect.width / 2, height / 2)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    func drawText(_ text: String, at origin: NSPoint, font: NSFont,
                  color: NSColor, alignRight: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        let point = alignRight
            ? NSPoint(x: origin.x - size.width, y: origin.y - size.height / 2)
            : NSPoint(x: origin.x - size.width / 2, y: origin.y)
        text.draw(at: point, withAttributes: attributes)
    }

    func yAxisLabel(_ value: Double) -> String {
        PanelFormats.formatTokens(value)
    }
}

@MainActor
final class TokenAreaChartView: HourlyChartView {
    override func seriesValue(_ point: UsagePoint) -> Double {
        point.totalTokens
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard points.count > 1 else { return }
        let plot = NSRect(x: leftInset,
                          y: topInset,
                          width: max(1, bounds.width - leftInset - 8),
                          height: max(1, bounds.height - topInset - bottomInset))
        let maxValue = seriesMax
        guard maxValue > 0 else { return }
        let slot = plot.width / CGFloat(points.count)

        var inputPoints: [NSPoint] = []
        var outputPoints: [NSPoint] = []
        for (index, point) in points.enumerated() {
            let x = plot.minX + slot * (CGFloat(index) + 0.5)
            let inputY = plot.maxY - plot.height * CGFloat(point.inputTokens / maxValue)
            let outputY = plot.maxY - plot.height * CGFloat((point.inputTokens + point.outputTokens) / maxValue)
            inputPoints.append(NSPoint(x: x, y: inputY))
            outputPoints.append(NSPoint(x: x, y: outputY))
        }

        fillArea(baseline: plot.maxY, edge: inputPoints, color: ChartPalette.input.withAlphaComponent(0.2))
        strokeArea(inputPoints, color: ChartPalette.input)
        fillArea(baseline: inputPoints, edge: outputPoints, color: ChartPalette.output.withAlphaComponent(0.35))
        strokeArea(outputPoints, color: ChartPalette.output)
    }

    override func drawSeries(in plot: NSRect, slot: CGFloat, index: Int, x: CGFloat,
                             point: UsagePoint, maxValue: Double) {}

    override func hoverRows(_ point: UsagePoint) -> [(String, String)] {
        [
            ("Input", PanelFormats.formatTokens(point.inputTokens)),
            ("Output", PanelFormats.formatTokens(point.outputTokens)),
            ("Total", PanelFormats.formatTokens(point.totalTokens)),
        ]
    }

    override var seriesColors: [NSColor] { [ChartPalette.output, ChartPalette.input, ChartPalette.total] }

    private func fillArea(baseline: CGFloat, edge: [NSPoint], color: NSColor) {
        guard edge.count > 1 else { return }
        let path = NSBezierPath()
        color.setFill()
        path.move(to: NSPoint(x: edge.first!.x, y: baseline))
        path.line(to: edge.first!)
        for point in edge.dropFirst() {
            path.line(to: point)
        }
        path.line(to: NSPoint(x: edge.last!.x, y: baseline))
        path.close()
        path.fill()
    }

    private func fillArea(baseline edgeBottom: [NSPoint], edge: [NSPoint], color: NSColor) {
        guard edge.count > 1, edgeBottom.count == edge.count else { return }
        let path = NSBezierPath()
        color.setFill()
        path.move(to: edgeBottom.first!)
        for point in edge {
            path.line(to: point)
        }
        for point in edgeBottom.reversed() {
            path.line(to: point)
        }
        path.close()
        path.fill()
    }

    private func strokeArea(_ edge: [NSPoint], color: NSColor) {
        guard edge.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.setStroke()
        path.move(to: edge.first!)
        for point in edge.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }
}

@MainActor
final class CostBarChartView: HourlyChartView {
    override func seriesValue(_ point: UsagePoint) -> Double { point.cost }

    override func drawSeries(in plot: NSRect, slot: CGFloat, index: Int, x: CGFloat,
                             point: UsagePoint, maxValue: Double) {
        bar(in: plot, x: x, slot: slot, value: point.cost, maxValue: maxValue, color: ChartPalette.cost)
    }

    override func hoverRows(_ point: UsagePoint) -> [(String, String)] {
        [("Cost", PanelFormats.formatCost(point.cost))]
    }

    override func yAxisLabel(_ value: Double) -> String {
        value >= 1 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}

@MainActor
final class RequestsBarChartView: HourlyChartView {
    override func seriesValue(_ point: UsagePoint) -> Double { Double(point.requests) }

    override func drawSeries(in plot: NSRect, slot: CGFloat, index: Int, x: CGFloat,
                             point: UsagePoint, maxValue: Double) {
        bar(in: plot, x: x, slot: slot, value: Double(point.requests), maxValue: maxValue, color: ChartPalette.requests)
    }

    override func hoverRows(_ point: UsagePoint) -> [(String, String)] {
        [("Requests", String(point.requests))]
    }

    override func yAxisLabel(_ value: Double) -> String {
        String(Int(value))
    }
}
