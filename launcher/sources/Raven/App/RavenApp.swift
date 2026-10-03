import SwiftUI

@main
struct RavenApp: App {
    @NSApplicationDelegateAdaptor(RavenLifecycle.self) private var lifecycle
    @State private var model = AppModel(store: .shared)

    var body: some Scene {
        Window("Raven", id: "main") {
            RootView()
                .environment(model)
                .environment(model.store)
                .onAppear { UsageStore.shared.start() }
        }
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { RavenCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.store)
        }
    }
}
