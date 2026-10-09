import AppKit
import SwiftUI

struct Badge: View {
    var text: String
    var tint: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct Glyph: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.3))
    }
}

struct FamilyGlyph: View {
    var family: ModelFamily
    var size: CGFloat = 28

    var body: some View {
        if let logo = FamilyLogo.logo(for: family) {
            let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            ZStack {
                if logo.fillsTile {
                    Image(nsImage: logo.image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(logo.zoom)
                } else {
                    Color(nsColor: .textBackgroundColor)
                    if logo.isTemplate {
                        Image(nsImage: logo.image)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.primary)
                            .padding(size * 0.2)
                    } else {
                        Image(nsImage: logo.image)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.2)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.7), lineWidth: 0.5) }
            .accessibilityLabel(family.title)
        } else {
            Glyph(symbol: family.symbol, tint: family.tint, size: size)
        }
    }
}

enum ChannelLogo {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ kind: String) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = Bundle.main.url(forResource: kind, withExtension: "png", subdirectory: "Logos")
            .flatMap(NSImage.init(contentsOf:))
        cache[kind] = .some(image)
        return image
    }
}

struct FamilyLogo {
    let image: NSImage
    let isTemplate: Bool
    let fillsTile: Bool
    let zoom: CGFloat

    private struct Spec {
        var file: String
        var ext: String
        var isTemplate = false
        var fillsTile = false
        var zoom: CGFloat = 1
    }

    private static let specs: [ModelFamily: Spec] = [
        .claude: Spec(file: "claude", ext: "png", fillsTile: true),
        .gpt: Spec(file: "openai", ext: "svg", isTemplate: true),
        .gemini: Spec(file: "gemini", ext: "png"),
        .deepseek: Spec(file: "deepseek", ext: "svg"),
        .llama: Spec(file: "llama", ext: "svg"),
        .mistral: Spec(file: "mistral", ext: "svg"),
        .qwen: Spec(file: "qwen", ext: "png"),
        .grok: Spec(file: "grok", ext: "svg", isTemplate: true),
        .kimi: Spec(file: "kimi", ext: "svg", isTemplate: true),
        .minimax: Spec(file: "minimax", ext: "svg"),
        .glm: Spec(file: "glm", ext: "png", fillsTile: true),
        .mimo: Spec(file: "mimo", ext: "png", fillsTile: true, zoom: 1.4),
    ]

    private static var cache: [ModelFamily: FamilyLogo?] = [:]

    static func logo(for family: ModelFamily) -> FamilyLogo? {
        if let cached = cache[family] { return cached }
        let loaded = load(family)
        cache[family] = .some(loaded)
        return loaded
    }

    private static func rasterized(_ source: NSImage, asMask: Bool) -> NSImage {
        let pixels = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let size = source.size
        let scale = min(CGFloat(pixels) / size.width, CGFloat(pixels) / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        source.draw(in: NSRect(x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2,
                               width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        if asMask, let data = rep.bitmapData {
            for offset in stride(from: 0, to: rep.bytesPerRow * pixels, by: 4) {
                let alpha = Double(data[offset + 3]) / 255
                guard alpha > 0 else { continue }
                let red = Double(data[offset]) / 255 / alpha
                let green = Double(data[offset + 1]) / 255 / alpha
                let blue = Double(data[offset + 2]) / 255 / alpha
                let darkness = 1 - (0.299 * red + 0.587 * green + 0.114 * blue)
                data[offset] = 0
                data[offset + 1] = 0
                data[offset + 2] = 0
                data[offset + 3] = UInt8(max(0, min(1, darkness * alpha)) * 255)
            }
        }
        let result = NSImage(size: NSSize(width: pixels, height: pixels))
        result.addRepresentation(rep)
        return result
    }

    private static func load(_ family: ModelFamily) -> FamilyLogo? {
        guard let spec = specs[family],
              let url = Bundle.main.url(forResource: spec.file, withExtension: spec.ext, subdirectory: "Logos"),
              let source = NSImage(contentsOf: url) else { return nil }
        return FamilyLogo(image: rasterized(source, asMask: spec.isTemplate), isTemplate: spec.isTemplate,
                          fillsTile: spec.fillsTile, zoom: spec.zoom)
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}

struct StatusDot: View {
    var tint: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(tint).frame(width: size, height: size)
    }
}

struct Notice: View {
    enum Severity {
        case error, warning, success, info

        var symbol: String {
            switch self {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: .red
            case .warning: .yellow
            case .success: .green
            case .info: .accentColor
            }
        }
    }

    var message: String?
    var severity: Severity = .error

    var body: some View {
        if let message, !message.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: severity.symbol).foregroundStyle(severity.tint)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .background(severity.tint.opacity(0.09), in: .rect(cornerRadius: Radius.tile))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.tile)
                    .strokeBorder(severity.tint.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

struct LoadingState: View {
    var message: String = "Loading…"

    var body: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyState<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String?
    var actions: Actions

    init(symbol: String, title: String, message: String? = nil) where Actions == EmptyView {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = EmptyView()
    }

    init(symbol: String, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HealthBadge: View {
    private let usage = UsageStore.shared

    var body: some View {
        let state = Self.state(live: usage.isLive, up: usage.isProxyUp, dropped: usage.droppedRecords)
        HStack(spacing: 6) {
            StatusDot(tint: state.tint)
            Text(state.label).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help(state.help)
    }

    static func state(live: Bool, up: Bool, dropped: Int) -> (label: String, tint: Color, help: String) {
        if live && dropped > 0 {
            return ("Delayed", .yellow, "Raven is running, but the live usage feed dropped updates — counts reflect the last full snapshot")
        }
        if live { return ("Running", .green, "Raven is running and streaming usage") }
        if up { return ("Running", .green, "Raven is running") }
        return ("Offline", .red, "Raven isn't reachable on :3458")
    }
}
