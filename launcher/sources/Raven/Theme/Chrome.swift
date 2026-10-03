import SwiftUI

struct Pill: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(RavenFont.numeric(10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct TintedIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 26
    var cornerRadius: CGFloat = 7

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: cornerRadius))
    }
}

struct StatusDot: View {
    var tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Metrics.cardRadius
    var tint: Color?
    var interactive = false
    var padding: CGFloat = Metrics.spacing4
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(cardGlass, in: .rect(cornerRadius: cornerRadius))
    }

    private var cardGlass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

struct SurfaceBox<Content: View>: View {
    var cornerRadius: CGFloat = Metrics.controlRadius
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

struct RavenLoader: View {
    var message: String = "Loading…"

    var body: some View {
        HStack(spacing: Metrics.spacing2) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(RavenFont.body)
                .foregroundStyle(.secondary)
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

    init(symbol: String, title: String, message: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            actions
        }
    }
}

struct FormLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(RavenFont.caption)
            .foregroundStyle(.secondary)
    }
}
