import SwiftUI

struct RavenCommands: Commands {
    let store: ProviderStore
    let workspace: Workspace
    @Bindable var shell: ShellState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Provider…") { workspace.addProvider() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace.providerDraft != nil)
            Button("Add Local Proxy") { workspace.addLocalProxy() }
                .disabled(workspace.providerDraft != nil)
        }

        CommandMenu("Launch") {
            Button("Launch") { workspace.launch() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canLaunch || workspace.isLaunching)

            Menu("Client") {
                ForEach(ProviderKind.allCases) { kind in
                    Button {
                        store.client = kind
                    } label: {
                        if store.client == kind {
                            Label(kind.displayName, systemImage: "checkmark")
                        } else {
                            Text(kind.displayName)
                        }
                    }
                }
            }

            Button("Choose Folder…") { workspace.chooseWorkdir() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button(pinTitle) { togglePin() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(store.selectedItem == nil)

            Button("Set Context Window…") { editWindow() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store.selectedItem == nil)

            Divider()

            Button(workspace.didCopyScript ? "Copied" : "Copy Launch Script") { workspace.copyScript() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!store.canLaunch)

            Button("Show Launch Script…") { workspace.isShowingScript = true }
                .disabled(!store.canLaunch)
        }

        CommandMenu("Provider") {
            Button("Refresh") { workspace.refreshVisible() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Refresh All") { workspace.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.providers.isEmpty)

            Divider()

            Button("Edit Provider…") { editProvider() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(workspace.activeProvider == nil)

            Button("Remove Provider…") { removeProvider() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(workspace.activeProvider == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("All Models") { workspace.destination = .library }
                .keyboardShortcut("1", modifiers: .command)
            Button("Pinned") { workspace.destination = .pinned }
                .keyboardShortcut("2", modifiers: .command)
            Button("Recents") { workspace.destination = .recents }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Overview") { workspace.destination = .overview }
                .keyboardShortcut("4", modifiers: .command)
            Button("Usage") { workspace.destination = .usage }
                .keyboardShortcut("5", modifiers: .command)
            Button("Accounts") { workspace.destination = .accounts }
                .keyboardShortcut("6", modifiers: .command)
            Button("Models") { workspace.destination = .providersPage }
                .keyboardShortcut("7", modifiers: .command)
            Button("Pricing") { workspace.destination = .pricing }
                .keyboardShortcut("8", modifiers: .command)

            Divider()
        }
    }

    private var pinTitle: String {
        guard let item = store.selectedItem else { return "Pin Model" }
        return store.isPinned(item) ? "Unpin Model" : "Pin Model"
    }

    private func togglePin() {
        guard let item = store.selectedItem else { return }
        store.togglePin(item)
    }

    private func editWindow() {
        guard let item = store.selectedItem else { return }
        workspace.beginEditingWindow(item)
    }

    private func editProvider() {
        guard let provider = workspace.activeProvider else { return }
        workspace.edit(provider)
    }

    private func removeProvider() {
        guard let provider = workspace.activeProvider else { return }
        workspace.confirmRemoval(of: provider)
    }
}
