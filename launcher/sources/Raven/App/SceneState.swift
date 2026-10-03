import SwiftUI

enum SheetRequest: Identifiable {
    case provider(ProviderDraft)
    case contextWindow(WindowDraft)
    case script

    var id: String {
        switch self {
        case .provider: "provider"
        case .contextWindow: "window"
        case .script: "script"
        }
    }
}
