import SwiftUI

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let tile: CGFloat = 12
    static let control: CGFloat = 8
}

enum Layout {
    static let sidebarMin: CGFloat = 210
    static let sidebarIdeal: CGFloat = 236
    static let sidebarMax: CGFloat = 320
}

extension Font {
    static var identifier: Font { .body }
    static var identifierSmall: Font { .subheadline }
    static var script: Font { .system(.callout, design: .monospaced) }
    static var figure: Font { .callout.monospacedDigit() }
    static var figureSmall: Font { .subheadline.monospacedDigit() }
    static var metric: Font { .title.weight(.semibold).monospacedDigit() }
}

extension ModelFamily {
    var tint: Color {
        switch self {
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
        case .mimo: .orange
        case .other: .secondary
        }
    }
}

extension Provider {
    var accent: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red]
        let seed = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[seed % palette.count]
    }
}

enum Palette {
    static let input = Color.indigo
    static let output = Color.mint
    static let cost = Color.orange
    static let requests = Color.blue
    static let good = Color.green
    static let warn = Color.yellow
    static let bad = Color.red

    static func remaining(_ fraction: Double) -> Color {
        if fraction > 0.4 { return good }
        if fraction > 0.15 { return warn }
        return bad
    }
}
