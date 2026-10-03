import AppKit

enum RavenMetrics {
    static let spacing1: CGFloat = 4
    static let spacing2: CGFloat = 8
    static let spacing3: CGFloat = 12
    static let spacing4: CGFloat = 16
    static let spacing5: CGFloat = 20
    static let spacing6: CGFloat = 24
    static let contentMargin: CGFloat = 20
    static let cardRadius: CGFloat = 16
    static let tableRowHeight: CGFloat = 28
    static let minHitTarget: CGFloat = 28
    static let maxPanelWidth: CGFloat = 1080
    static let launchBarHeight: CGFloat = 56
    static let searchMinWidth: CGFloat = 160
    static let searchMaxWidth: CGFloat = 260
}

enum RavenType {
    static func headline() -> NSFont { .systemFont(ofSize: 14, weight: .semibold) }
    static func body() -> NSFont { .systemFont(ofSize: 13) }
    static func caption() -> NSFont { .systemFont(ofSize: 11) }
    static func micro() -> NSFont { .systemFont(ofSize: 10, weight: .medium) }
    static func numeric(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    static func mono(ofSize size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

enum RavenColors {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}

@MainActor enum AppKitTheme {
    static let providerPalette: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal,
        .systemIndigo, .systemGreen, .systemMint, .systemCyan, .systemRed,
    ]

    static func providerAccent(_ provider: Provider) -> NSColor {
        let seed = provider.id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return providerPalette[seed % providerPalette.count]
    }

    static func familyTint(_ family: ModelFamily) -> NSColor {
        switch family {
        case .claude: .systemOrange
        case .gpt: .systemGreen
        case .gemini: .systemBlue
        case .deepseek: .systemIndigo
        case .llama: .systemPurple
        case .mistral: .systemRed
        case .qwen: .systemCyan
        case .grok: .systemGray
        case .kimi: .systemTeal
        case .minimax: .systemPink
        case .glm: .systemMint
        case .other: .secondaryLabelColor
        }
    }

    static func statusTint(_ status: ProviderStatus) -> NSColor {
        switch status {
        case .failed: .systemRed
        case .ready: .systemGreen
        case .loading, .empty: .secondaryLabelColor
        }
    }

    static func symbol(_ name: String,
                       color: NSColor? = nil,
                       pointSize: CGFloat? = nil,
                       accessibilityLabel: String? = nil) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize ?? 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(configuration) else { return nil }
        guard let color else { return image }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = accessibilityLabel
        return tinted
    }

    static func label(_ string: String,
                      font: NSFont,
                      color: NSColor,
                      lineLimit: Int = 0,
                      flexible: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        if lineLimit == 1 { field.cell?.truncatesLastVisibleLine = true }
        field.maximumNumberOfLines = lineLimit == 0 ? 0 : lineLimit
        if flexible {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return field
    }

    static func wrappingLabel(_ string: String,
                              font: NSFont = RavenType.body(),
                              color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        return field
    }

    static func sectionHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title.uppercased())
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .tertiaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.allowsDefaultTighteningForTruncation = true
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    static func glassButton(title: String,
                            symbol: String? = nil,
                            prominent: Bool = false,
                            action: Selector,
                            target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .glass
        button.controlSize = .large
        button.setButtonType(.momentaryPushIn)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        if prominent {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        button.setAccessibilityLabel(title)
        return button
    }

    static func iconButton(symbol: String,
                           tooltip: String? = nil,
                           tint: NSColor = .secondaryLabelColor,
                           accessibilityLabel: String? = nil,
                           action: Selector,
                           target: AnyObject) -> NSButton {
        let button = HoverImageButton(title: "", target: target, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        button.contentTintColor = tint
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel(accessibilityLabel ?? tooltip)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        return button
    }

    static func pill(_ string: String, color: NSColor) -> PillLabel {
        let field = PillLabel(string: string)
        field.font = RavenType.numeric(ofSize: 10, weight: .medium)
        field.textColor = color
        field.baseColor = color
        field.drawsBackground = false
        field.isBezeled = false
        field.alignment = .center
        return field
    }

    static func glassCard(cornerRadius: CGFloat = RavenMetrics.cardRadius,
                          tint: NSColor? = nil,
                          interactive: Bool = false,
                          style: NSGlassEffectView.Style = .regular) -> GlassCardView {
        GlassCardView(cornerRadius: cornerRadius, tint: tint, interactive: interactive, style: style)
    }
}

@MainActor
final class GlassCardView: NSGlassEffectView {
    let content = NSView()

    init(cornerRadius: CGFloat = RavenMetrics.cardRadius,
         tint: NSColor? = nil,
         interactive: Bool = false,
         style: NSGlassEffectView.Style = .regular) {
        super.init(frame: .zero)
        self.cornerRadius = cornerRadius
        self.tintColor = tint
        self.style = style
        effectIsInteractive = interactive
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView = content
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func embed(_ subview: NSView, insets: CGFloat = RavenMetrics.spacing4) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: content.topAnchor, constant: insets),
            subview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: insets),
            subview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -insets),
            subview.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -insets),
        ])
    }
}

@MainActor
class InsetLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 20, height: max(size.height, 18))
    }
}

@MainActor
final class PillLabel: InsetLabel {
    var baseColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.backgroundColor = baseColor.withAlphaComponent(0.14).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

@MainActor
class DynamicSurfaceView: NSView {
    var fill: () -> NSColor
    var stroke: (() -> NSColor?)?
    var cornerRadius: CGFloat

    init(fill: @escaping () -> NSColor,
         stroke: (() -> NSColor?)? = nil,
         cornerRadius: CGFloat = 10) {
        self.fill = fill
        self.stroke = stroke
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fill().cgColor
        if let color = stroke?() {
            layer?.borderWidth = 1
            layer?.borderColor = color.cgColor
        } else {
            layer?.borderWidth = 0
        }
    }
}

@MainActor
final class SurfaceBoxView: DynamicSurfaceView {
    let content = NSStackView()

    init(fill: @escaping () -> NSColor = { NSColor.controlBackgroundColor.withAlphaComponent(0.6) },
         stroke: (() -> NSColor?)? = { NSColor.separatorColor },
         cornerRadius: CGFloat = 10,
         insets: CGFloat = 12) {
        super.init(fill: fill, stroke: stroke, cornerRadius: cornerRadius)
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: insets, left: insets, bottom: insets, right: insets)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ views: [NSView]) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            content.addArrangedSubview(view)
        }
        content.isHidden = views.isEmpty
    }
}

@MainActor
final class HoverImageButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = (hovering ? NSColor.quaternaryLabelColor : NSColor.clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }
}

@MainActor
final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, prominent: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .glass
        controlSize = .large
        setButtonType(.momentaryPushIn)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            imagePosition = .imageLeading
            self.image = image
        }
        if prominent {
            bezelColor = .controlAccentColor
            contentTintColor = .white
        }
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
