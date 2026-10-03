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

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String?
    var actions: AnyView?

    init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = nil
    }

    init<A: View>(symbol: String, title: String, message: String? = nil, @ViewBuilder actions: () -> A) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = AnyView(actions())
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actions {
                actions
            }
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
