import Foundation

struct ZoneSpec {
    var key: String
    var title: String
    var symbol: String
    var kind: String
    var presets: Bool
    var emptyHint: String

    var match: (ProviderEntry) -> Bool { { $0.kind == kind } }
    var blank: () -> ProviderEntry { { PanelLogic.blankProviderEntry(kind: kind, name: kind) } }

    static let managed: [ZoneSpec] = [
        ZoneSpec(key: "workbuddy", title: "WorkBuddy", symbol: "cpu", kind: "workbuddy", presets: false,
                 emptyHint: "No models pinned. Unlisted WorkBuddy models still route by name."),
        ZoneSpec(key: "antigravity", title: "Antigravity", symbol: "sparkles", kind: "antigravity", presets: true,
                 emptyHint: "No models pinned. Unlisted Antigravity models still route by name."),
    ]
}
