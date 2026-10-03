import SwiftUI

@MainActor
final class RavenRuntime {
    static let shared = RavenRuntime()

    let store = ProviderStore.shared
    let workspace: Workspace
    let shell = ShellState()

    private init() {
        workspace = Workspace(store: store)
    }
}
