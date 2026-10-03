import SwiftUI

struct BadgeText: View {
    var text: String
    var tint: Color
    var soft = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(soft ? Color.secondary : tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct QuotaValue: View {
    var percent: String
    var reset: String?
    var fraction: Double?

    var body: some View {
        HStack(spacing: 3) {
            Text(percent)
                .font(RavenFont.numeric(11, weight: .medium))
                .foregroundStyle(color)
            if let reset {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        guard let fraction else { return .primary }
        if fraction < 0.6 { return .green }
        if fraction < 0.85 { return .yellow }
        return .red
    }
}

struct FooterStrong: View {
    var text: String
    var suffix: String?

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            if let suffix {
                Text(" · \(suffix)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

struct PanelNotice: View {
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: severity.symbol)
                    .foregroundStyle(severity.tint)
                Text(message)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(severity.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(severity.tint.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

struct StatTile: View {
    var icon: String
    var label: String
    var value: String
    var sub: String?
    var badge: String?
    var tint: Color = .accentColor

    var body: some View {
        GlassCard(interactive: true) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .imageScale(.small)
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                        .background(tint.opacity(0.14), in: Circle())
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let badge {
                        Pill(text: badge)
                    }
                }
                Text(value)
                    .font(RavenFont.numeric(24, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sub ?? " ")
                    .font(RavenFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 92)
    }
}

struct ChartCard<Content: View>: View {
    var title: String
    var subtitle: String
    var legend: [(Color, String)] = []
    var chartHeight: CGFloat = 200
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RavenFont.headline)
                HStack(spacing: 10) {
                    Text(subtitle)
                        .font(RavenFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ForEach(Array(legend.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(entry.0)
                            Text(entry.1)
                                .font(RavenFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                content
                    .frame(height: chartHeight)
            }
        }
    }
}

struct PanelPageHeader: View {
    var title: String
    var subtitle: String?
    var icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9))
                .help(title)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(RavenFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.top, Metrics.spacing2)
    }
}

struct PanelSection<Content: View>: View {
    var title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }
            content
        }
    }
}
