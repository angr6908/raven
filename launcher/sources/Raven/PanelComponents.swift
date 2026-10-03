import AppKit
import Observation

@MainActor
final class StatCardView: NSView {
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let subLabel: NSTextField
    private let badgeLabel: PillLabel

    init(icon: String, label: String, value: String, sub: String?, badge: String?) {
        titleLabel = AppKitTheme.label(label, font: .systemFont(ofSize: 12, weight: .medium),
                                       color: .secondaryLabelColor, lineLimit: 1, flexible: true)
        valueLabel = AppKitTheme.label(value,
                                       font: RavenType.numeric(ofSize: 22, weight: .semibold),
                                       color: .labelColor, lineLimit: 1)
        subLabel = AppKitTheme.label("", font: RavenType.caption(), color: .secondaryLabelColor,
                                     lineLimit: 1, flexible: true)
        badgeLabel = AppKitTheme.pill("", color: .secondaryLabelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = AppKitTheme.glassCard(interactive: true)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [titleLabel, iconView])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let stack = NSStackView(views: [header, valueLabel, subLabel, badgeLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.embed(stack, insets: RavenMetrics.spacing4)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        update(value: value, sub: sub, badge: badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(value: String, sub: String?, badge: String?) {
        valueLabel.stringValue = value
        subLabel.stringValue = sub ?? ""
        subLabel.isHidden = sub == nil
        badgeLabel.stringValue = badge ?? ""
        badgeLabel.isHidden = badge == nil
    }
}

@MainActor
final class ChartCardView: NSView {
    let chart: HourlyChartView

    init(title: String, subtitle: String, chart: HourlyChartView, chartHeight: CGFloat = 200,
         legend: [(color: NSColor, label: String)]? = nil) {
        self.chart = chart
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = AppKitTheme.glassCard()

        let titleLabel = AppKitTheme.label(title, font: RavenType.headline(), color: .labelColor,
                                           flexible: true)
        let subtitleLabel = AppKitTheme.label(subtitle, font: RavenType.caption(),
                                              color: .secondaryLabelColor, flexible: true)
        chart.translatesAutoresizingMaskIntoConstraints = false

        var bodyViews: [NSView] = [titleLabel, subtitleLabel]
        if let legend {
            let legendStack = NSStackView()
            legendStack.orientation = .horizontal
            legendStack.alignment = .centerY
            legendStack.spacing = 10
            for entry in legend {
                let dot = NSImageView()
                dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: entry.label)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
                dot.contentTintColor = entry.color
                let text = AppKitTheme.label(entry.label, font: RavenType.caption(),
                                             color: .secondaryLabelColor, lineLimit: 1)
                legendStack.addArrangedSubview(dot)
                legendStack.addArrangedSubview(text)
            }
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            legendStack.addArrangedSubview(spacer)
            bodyViews.append(legendStack)
        }
        bodyViews.append(chart)

        let stack = NSStackView(views: bodyViews)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.embed(stack, insets: RavenMetrics.spacing4)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            chart.heightAnchor.constraint(equalToConstant: chartHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class PanelSectionView: NSView {
    private let formSlot = NSStackView()
    private let bodySlot = NSStackView()
    private let titleLabel: NSTextField
    private let countPill: PillLabel
    private let actionsRow = NSStackView()

    init(title: String) {
        titleLabel = AppKitTheme.label(title, font: .systemFont(ofSize: 14, weight: .semibold),
                                       color: .labelColor, flexible: true)
        countPill = AppKitTheme.pill("", color: .secondaryLabelColor)
        countPill.isHidden = true
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = AppKitTheme.glassCard()

        let headerLeading = NSStackView(views: [titleLabel, countPill])
        headerLeading.orientation = .horizontal
        headerLeading.alignment = .centerY
        headerLeading.spacing = 8
        titleLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 8

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [headerLeading, headerSpacer, actionsRow])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        for slot in [formSlot, bodySlot] {
            slot.orientation = .vertical
            slot.alignment = .width
            slot.spacing = 12
        }

        let shell = NSStackView(views: [header, formSlot, bodySlot])
        shell.orientation = .vertical
        shell.alignment = .width
        shell.spacing = 12
        shell.translatesAutoresizingMaskIntoConstraints = false
        card.embed(shell, insets: 14)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var bodyContent: NSStackView { bodySlot }
    var formContent: NSStackView { formSlot }

    func setCount(_ count: Int?) {
        countPill.stringValue = count.map { String($0) } ?? ""
        countPill.isHidden = count == nil
    }

    func setActions(_ buttons: [NSButton]) {
        actionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for button in buttons {
            actionsRow.addArrangedSubview(button)
        }
    }

    func setForm(_ content: NSView?) {
        setForm([content].compactMap { $0 })
    }

    func setForm(_ contents: [NSView]) {
        replace(in: formSlot, with: contents)
    }

    func setBody(_ content: NSView?) {
        replace(in: bodySlot, with: [content].compactMap { $0 })
    }

    func setBody(_ contents: [NSView]) {
        replace(in: bodySlot, with: contents)
    }

    private func replace(in slot: NSStackView, with contents: [NSView]) {
        slot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for content in contents {
            content.translatesAutoresizingMaskIntoConstraints = false
            slot.addArrangedSubview(content)
        }
        slot.isHidden = contents.isEmpty
    }
}

@MainActor
final class PanelNoticeView: DynamicSurfaceView {
    enum Severity {
        case error
        case warning
        case success
        case info

        var symbol: String {
            switch self {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .error: .systemRed
            case .warning: .systemYellow
            case .success: .systemGreen
            case .info: .controlAccentColor
            }
        }
    }

    private let iconView = NSImageView()
    private let label: NSTextField

    init() {
        label = AppKitTheme.label("", font: .systemFont(ofSize: 12), color: .labelColor,
                                  lineLimit: 3, flexible: true)
        super.init(fill: { NSColor.controlBackgroundColor.withAlphaComponent(0.6) },
                   stroke: { NSColor.separatorColor },
                   cornerRadius: 10)
        iconView.image = NSImage(systemSymbolName: Severity.error.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = Severity.error.tint
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.isSelectable = true
        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        isHidden = true
    }

    func show(_ message: String?, severity: Severity = .error) {
        iconView.image = NSImage(systemSymbolName: severity.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = severity.tint
        label.stringValue = message ?? ""
        setAccessibilityLabel(message)
        isHidden = message == nil || message?.isEmpty == true
    }
}

@MainActor
@Observable
final class AutoSaveScheduler {
    enum Status: Equatable {
        case idle, saving, saved, failed(String)
    }

    private(set) var status: Status = .idle

    private var task: Task<Void, Never>?

    func schedule(_ save: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        status = .saving
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                try await save()
                guard !Task.isCancelled else { return }
                self?.status = .saved
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed((error as? PanelError)?.noticeText ?? error.localizedDescription)
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        status = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
