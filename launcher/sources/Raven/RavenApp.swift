import SwiftUI

@main
struct RavenApp: App {
    private let store = ProviderStore.shared

    var body: some Scene {
        Window("Raven", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandMenu("Raven") {
                Button("Add Provider…", systemImage: "plus") {
                    store.beginAddingProvider()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await store.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.providers.isEmpty)
            }
        }
    }
}
