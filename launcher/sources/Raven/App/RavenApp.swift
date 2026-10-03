import SwiftUI

@main
struct RavenApp: App {
    @NSApplicationDelegateAdaptor(RavenLifecycle.self) private var lifecycle
    private let runtime = RavenRuntime.shared

    var body: some Scene {
        Window("Raven", id: "main") {
            RootView(store: runtime.store, workspace: runtime.workspace, shell: runtime.shell)
                .environment(runtime.store)
                .environment(runtime.workspace)
                .onAppear { UsageStore.shared.start() }
        }
        .defaultSize(width: 1020, height: 660)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            RavenCommands(store: runtime.store, workspace: runtime.workspace, shell: runtime.shell)
        }

        Settings {
            SettingsView(store: runtime.store, workspace: runtime.workspace)
        }
    }
}
