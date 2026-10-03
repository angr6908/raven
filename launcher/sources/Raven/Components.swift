import AppKit

@MainActor
final class UnavailableView: NSView {
    init(symbol: String,
         symbolColor: NSColor = .secondaryLabelColor,
         title: String,
         description: String? = nil,
         actions: [NSButton] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            iconView.image = image
            iconView.contentTintColor = symbolColor
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = AppKitTheme.label(title, font: .systemFont(ofSize: 18, weight: .semibold),
                                           color: .labelColor)
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        var views: [NSView] = [iconView, titleLabel]
        if let description {
            let body = NSTextField(wrappingLabelWithString: description)
            body.font = RavenType.body()
            body.textColor = .secondaryLabelColor
            body.alignment = .center
            body.isSelectable = true
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
            views.append(body)
        }
        if !actions.isEmpty {
            let row = NSStackView(views: actions)
            row.orientation = .horizontal
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: RavenMetrics.spacing2, left: 0, bottom: 0, right: 0)
            views.append(row)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = RavenMetrics.spacing2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: RavenMetrics.spacing6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -RavenMetrics.spacing6),
            iconView.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class CenteredLoaderView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = AppKitTheme.label(message, font: RavenType.body(), color: .secondaryLabelColor)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = RavenMetrics.spacing2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
