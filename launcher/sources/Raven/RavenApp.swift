import SwiftUI

@main
struct RavenApp: App {
    private let store: ProviderStore
    private let workspace: Workspace

    init() {
        let store = ProviderStore.shared
        self.store = store
        workspace = Workspace(store: store)
    }

    var body: some Scene {
        Window("Raven", id: "main") {
            MainWindow()
                .environment(store)
                .environment(workspace)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1020, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            RavenCommands(store: store, workspace: workspace)
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(workspace)
        }
    }
}

struct RavenCommands: Commands {
    let store: ProviderStore
    let workspace: Workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Provider…", systemImage: "plus") {
                workspace.addProvider()
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Launch") {
            Button("Launch", systemImage: "play.fill") {
                workspace.launch()
            }
            .keyboardShortcut(.return)
            .disabled(!store.canLaunch || workspace.isLaunching)

            Picker("Client", selection: clientBinding) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            Button("Choose Folder…", systemImage: "folder") {
                workspace.chooseWorkdir()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button(pinTitle, systemImage: "pin") {
                if let item = store.selectedItem {
                    store.togglePin(item)
                }
            }
            .keyboardShortcut("d")
            .disabled(store.selectedItem == nil)

            Button("Set Context Window…", systemImage: "slider.horizontal.3") {
                if let item = store.selectedItem {
                    workspace.beginEditingWindow(item)
                }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(store.selectedItem == nil)

            Divider()

            Button("Copy Launch Script", systemImage: "document.on.document") {
                workspace.copyScript()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!store.canLaunch)

            Button("Show Launch Script…", systemImage: "apple.terminal") {
                workspace.isShowingScript = true
            }
            .disabled(!store.canLaunch)
        }

        CommandMenu("Provider") {
            Button("Refresh", systemImage: "arrow.clockwise") {
                workspace.refreshActive()
            }
            .keyboardShortcut("r")
            .disabled(store.providers.isEmpty)

            Button("Refresh All", systemImage: "arrow.triangle.2.circlepath") {
                workspace.refreshAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.providers.isEmpty)

            Divider()

            Button("Edit Provider…", systemImage: "pencil") {
                if let provider = workspace.activeProvider {
                    workspace.edit(provider)
                }
            }
            .keyboardShortcut("e")
            .disabled(workspace.activeProvider == nil)

            Button("Remove Provider…", systemImage: "trash") {
                if let provider = workspace.activeProvider {
                    workspace.confirmRemoval(of: provider)
                }
            }
            .keyboardShortcut(.delete)
            .disabled(workspace.activeProvider == nil)
        }
    }

    private var clientBinding: Binding<ProviderKind> {
        Binding { store.client } set: { store.client = $0 }
    }

    private var pinTitle: String {
        if let item = store.selectedItem, store.isPinned(item) { return "Unpin Model" }
        return "Pin Model"
    }
}
