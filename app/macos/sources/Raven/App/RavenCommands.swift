import SwiftUI

struct RavenCommands: Commands {
    let model: AppModel

    private var store: ProviderStore { model.store }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Provider…") { model.addProvider() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Launch") {
            Button("Quick Launch…") { model.sheet = .quickLaunch }
                .keyboardShortcut("k", modifiers: .command)

            Button("Launch") { model.launch() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canLaunch || model.isLaunching)

            Menu("Client") {
                ForEach(ProviderKind.allCases) { kind in
                    Toggle(kind.displayName, isOn: Binding(
                        get: { store.client == kind },
                        set: { if $0 { store.client = kind } }))
                }
            }

            Button("Choose Folder…") { model.isChoosingFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button(pinTitle) {
                if let item = store.selectedItem { store.togglePin(item) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(store.selectedItem == nil)

            Divider()

            Button(model.copiedScript ? "Copied" : "Copy Launch Script") { model.copyScript() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!store.canLaunch)

            Button("Show Launch Script…") { model.sheet = .script }
                .disabled(!store.canLaunch)
        }

        CommandMenu("Provider") {
            Button("Refresh") { model.refreshCurrent() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Refresh All Providers") { model.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Edit Provider…") {
                if let provider = model.activeProvider { model.edit(provider) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.activeProvider?.isBuiltIn ?? true)

            Button("Remove Provider…") {
                if let provider = model.activeProvider { model.confirmRemoval(of: provider) }
            }
            .disabled(model.activeProvider?.isBuiltIn ?? true)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            pageButton("Models", .models, "1")
            pageButton("Pinned", .pinned, "2")
            pageButton("Recents", .recents, "3")
            Divider()
            pageButton("Overview", .overview, "4")
            pageButton("Usage", .usage, "5")
            pageButton("Accounts", .accounts, "6")
            pageButton("Routing", .routing, "7")
            pageButton("Pricing", .pricing, "8")
            Divider()
        }
    }

    private var pinTitle: String {
        guard let item = store.selectedItem else { return "Pin Model" }
        return store.isPinned(item) ? "Unpin Model" : "Pin Model"
    }

    private func pageButton(_ title: String, _ page: Page, _ key: KeyEquivalent) -> some View {
        Button(title) { model.page = page }
            .keyboardShortcut(key, modifiers: .command)
    }
}
