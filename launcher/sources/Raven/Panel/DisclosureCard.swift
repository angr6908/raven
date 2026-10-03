import SwiftUI

struct DisclosureCard<Accessory: View, Content: View>: View {
    var title: String
    var monospacedTitle = false
    var subtitle = ""
    var trailing = ""
    var badges: [String] = []
    var dimmed = false
    var isExpanded: Bool
    var onToggle: () -> Void
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(interactive: true, padding: 12) {
            VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
                header
                if isExpanded {
                    content
                }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title.isEmpty ? "unnamed" : title)
                                .font(monospacedTitle ? RavenFont.mono(13) : .system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                                Pill(text: badge)
                            }
                        }
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if !trailing.isEmpty {
                Text(trailing)
                    .font(RavenFont.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            accessory
        }
    }
}
