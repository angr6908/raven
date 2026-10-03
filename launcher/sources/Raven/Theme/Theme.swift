import SwiftUI

enum Metrics {
    static let spacing1: CGFloat = 4
    static let spacing2: CGFloat = 8
    static let spacing3: CGFloat = 12
    static let spacing4: CGFloat = 16
    static let spacing5: CGFloat = 20
    static let spacing6: CGFloat = 24
    static let contentMargin: CGFloat = 20
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let tableRowHeight: CGFloat = 28
    static let minHitTarget: CGFloat = 28
    static let maxPanelWidth: CGFloat = 1080
    static let launchBarHeight: CGFloat = 56
    static let searchMinWidth: CGFloat = 160
    static let searchMaxWidth: CGFloat = 260
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 250
    static let sidebarMax: CGFloat = 340
}

enum RavenFont {
    static var headline: Font { .system(size: 14, weight: .semibold) }
    static var title: Font { .system(size: 20, weight: .semibold) }
    static var body: Font { .system(size: 13) }
    static var caption: Font { .system(size: 11) }
    static var micro: Font { .system(size: 10, weight: .medium) }
    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

enum RavenTheme {
    static let providerPalette: [Color] = [
        .blue, .purple, .pink, .orange, .teal,
        .indigo, .green, .mint, .cyan, .red,
    ]

    static func providerAccent(_ provider: Provider) -> Color {
        let seed = provider.id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return providerPalette[seed % providerPalette.count]
    }

    static func familyTint(_ family: ModelFamily) -> Color {
        switch family {
        case .claude: .orange
        case .gpt: .green
        case .gemini: .blue
        case .deepseek: .indigo
        case .llama: .purple
        case .mistral: .red
        case .qwen: .cyan
        case .grok: .gray
        case .kimi: .teal
        case .minimax: .pink
        case .glm: .mint
        case .other: .secondary
        }
    }

    static func statusTint(_ status: ProviderStatus) -> Color {
        switch status {
        case .failed: .red
        case .ready: .green
        case .loading, .empty: .secondary
        }
    }
}
