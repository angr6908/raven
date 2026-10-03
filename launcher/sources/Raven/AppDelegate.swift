import AppKit

@MainActor
final class RavenRuntime {
    static let shared = RavenRuntime()

    let store = ProviderStore.shared
    let workspace: Workspace
    weak var presenter: AppDelegate?

    private init() {
        workspace = Workspace(store: store)
    }

    func sheetsChanged() {
        presenter?.reactToWorkspaceState()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    let runtime = RavenRuntime.shared
    private var windowController: MainWindowController!
    private var settingsController: SettingsWindowController?
    private var presentedSheet: String?
    private let presentationTracker = ObservationTracker()

    var store: ProviderStore { runtime.store }
    var workspace: Workspace { runtime.workspace }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.presenter = self
        NSApp.mainMenu = buildMenu()
        UsageStore.shared.start()
        windowController = MainWindowController()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        presentationTracker.start { [weak self] in
            guard let self else { return }
            _ = self.workspace.providerDraft
            _ = self.workspace.windowDraft
            _ = self.workspace.isShowingScript
            _ = self.workspace.pendingRemoval
            _ = self.workspace.launchError
            _ = self.workspace.isChoosingWorkdir
            self.reactToWorkspaceState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        UsageStore.shared.stop()
        AccountsStore.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    var mainWindow: NSWindow? { windowController?.window }

    func reactToWorkspaceState() {
        guard presentedSheet == nil else { return }
        if let draft = workspace.providerDraft {
            presentedSheet = "provider"
            presentProviderSheet(draft)
        } else if let draft = workspace.windowDraft {
            presentedSheet = "window"
            presentContextWindowSheet(draft)
        } else if workspace.isShowingScript {
            presentedSheet = "script"
            presentScriptSheet()
        } else if let provider = workspace.pendingRemoval {
            presentedSheet = "removal"
            presentRemovalConfirm(provider)
        } else if let message = workspace.launchError {
            presentedSheet = "error"
            presentLaunchError(message)
        } else if workspace.isChoosingWorkdir {
            presentedSheet = "workdir"
            presentWorkdirChooser()
        }
    }

    private func endSheet(_ kind: String) {
        presentedSheet = nil
        if kind == "provider" { workspace.providerDraft = nil }
        if kind == "window" { workspace.windowDraft = nil }
        if kind == "script" { workspace.isShowingScript = false }
        if kind == "removal" { workspace.pendingRemoval = nil }
        if kind == "error" { workspace.launchError = nil }
        if kind == "workdir" { workspace.isChoosingWorkdir = false }
    }

    private func presentProviderSheet(_ draft: ProviderDraft) {
        let controller = ProviderSheetViewController(draft: draft, workspace: workspace) { [weak self] commit in
            guard let self else { return }
            if commit { workspace.commitProviderDraft(draft) }
            self.endSheet("provider")
            self.reactToWorkspaceState()
        }
        presentAsSheet(NSWindowController(window: ModalSheet.window(content: controller,
                                                                   title: draft.isEditing ? "Edit Provider" : "Add Provider",
                                                                   size: NSSize(width: 500, height: 360))),
                       kind: "provider")
    }

    private func presentContextWindowSheet(_ draft: WindowDraft) {
        let controller = ContextWindowSheetViewController(draft: draft, workspace: workspace) { [weak self] commit in
            guard let self else { return }
            if commit { workspace.commitWindowDraft(draft) }
            self.endSheet("window")
            self.reactToWorkspaceState()
        }
        presentAsSheet(NSWindowController(window: ModalSheet.window(content: controller,
                                                                   title: "Context Window",
                                                                   size: NSSize(width: 470, height: 350))),
                       kind: "window")
    }

    private func presentScriptSheet() {
        let controller = ScriptSheetViewController(store: store, workspace: workspace) { [weak self] in
            self?.endSheet("script")
            self?.reactToWorkspaceState()
        }
        presentAsSheet(NSWindowController(window: ModalSheet.window(content: controller,
                                                                   title: "Launch Script",
                                                                   size: NSSize(width: 620, height: 460))),
                       kind: "script")
    }

    private func presentRemovalConfirm(_ provider: Provider) {
        guard let window = presentationParent else { endSheet("removal"); return }
        let alert = NSAlert()
        alert.messageText = "Remove this provider?"
        alert.informativeText = "Raven forgets \(provider.name)'s base URL and API key, along with its pins and context window overrides."
        alert.addButton(withTitle: "Remove \(provider.name)")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.workspace.removePendingProvider()
            }
            self?.endSheet("removal")
            self?.reactToWorkspaceState()
        }
    }

    private func presentLaunchError(_ message: String) {
        guard let window = presentationParent else { endSheet("error"); return }
        let alert = NSAlert()
        alert.messageText = "Couldn't launch"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.endSheet("error")
            self?.reactToWorkspaceState()
        }
    }

    private func presentWorkdirChooser() {
        guard let window = presentationParent else { endSheet("workdir"); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder to launch in"
        panel.prompt = "Use Folder"
        panel.directoryURL = store.workdir
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.store.workdir = url
            }
            self?.endSheet("workdir")
            self?.reactToWorkspaceState()
        }
    }

    private var window: NSWindow? { windowController.window }

    private var presentationParent: NSWindow? {
        guard let main = windowController.window else { return nil }
        if let key = NSApp.keyWindow, key !== main, key.sheetParent == nil,
           main.attachedSheet == nil {
            return key
        }
        return main
    }

    private func presentAsSheet(_ controller: NSWindowController, kind: String) {
        guard let sheet = controller.window, let parent = presentationParent else {
            endSheet(kind)
            return
        }
        (sheet as? ModalSheetWindow)?.onDismiss = { [weak self] in
            guard let self, self.presentedSheet == kind else { return }
            self.endSheet(kind)
            self.reactToWorkspaceState()
        }
        parent.beginSheet(sheet) { [weak self] _ in
            guard let self, self.presentedSheet == kind else { return }
            self.endSheet(kind)
            self.reactToWorkspaceState()
        }
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Raven", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        .target = self
        appMenu.addItem(.separator())
        let services = NSMenu()
        NSApp.servicesMenu = services
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Raven", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Raven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(tagItem("Add Provider…", #selector(addProvider), "n"))
        fileMenu.addItem(tagItem("Close", #selector(closeWindow), "w"))

        let launchItem = NSMenuItem()
        main.addItem(launchItem)
        let launchMenu = NSMenu(title: "Launch")
        launchItem.submenu = launchMenu
        launchMenu.delegate = self
        launchMenu.addItem(tagItem("Launch", #selector(launchModel), "\r", [.command]))
        let clientItem = launchMenu.addItem(withTitle: "Client", action: nil, keyEquivalent: "")
        let clientMenu = NSMenu(title: "Client")
        clientMenu.delegate = self
        clientItem.submenu = clientMenu
        for (index, kind) in ProviderKind.allCases.enumerated() {
            let item = NSMenuItem(title: kind.displayName, action: #selector(selectClient(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            clientMenu.addItem(item)
        }
        launchMenu.addItem(tagItem("Choose Folder…", #selector(chooseWorkdir), "o", [.command, .shift]))
        launchMenu.addItem(.separator())
        let pinItem = tagItem("Pin Model", #selector(togglePin), "d")
        pinItem.target = self
        launchMenu.addItem(pinItem)
        launchMenu.addItem(tagItem("Set Context Window…", #selector(setContextWindow), "k", [.command, .shift]))
        launchMenu.addItem(.separator())
        launchMenu.addItem(tagItem("Copy Launch Script", #selector(copyScript), "c", [.command, .shift]))
        launchMenu.addItem(tagItem("Show Launch Script…", #selector(showScript), ""))

        let providerItem = NSMenuItem()
        main.addItem(providerItem)
        let providerMenu = NSMenu(title: "Provider")
        providerItem.submenu = providerMenu
        providerMenu.addItem(tagItem("Refresh", #selector(refreshActive), "r"))
        providerMenu.addItem(tagItem("Refresh All", #selector(refreshAll), "r", [.command, .shift]))
        providerMenu.addItem(.separator())
        providerMenu.addItem(tagItem("Edit Provider…", #selector(editProvider), "e"))
        providerMenu.addItem(tagItem("Remove Provider…", #selector(removeProvider), "\u{8}"))

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(tagItem("Toggle Sidebar", #selector(toggleSidebar), "b"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(tagItem("All Models", #selector(goLibrary), "1"))
        viewMenu.addItem(tagItem("Pinned", #selector(goPinned), "2"))
        viewMenu.addItem(tagItem("Recents", #selector(goRecents), "3"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(tagItem("Overview", #selector(goOverview), "4"))
        viewMenu.addItem(tagItem("Usage", #selector(goUsage), "5"))
        viewMenu.addItem(tagItem("Accounts", #selector(goAccounts), "6"))
        viewMenu.addItem(tagItem("Models", #selector(goModels), "7"))
        viewMenu.addItem(tagItem("Pricing", #selector(goPricing), "8"))
        viewMenu.addItem(.separator())
        let refresh = viewMenu.addItem(withTitle: "Refresh", action: #selector(refreshVisible), keyEquivalent: "r")
        refresh.target = self
        let refreshAll = viewMenu.addItem(withTitle: "Refresh All Providers",
                                           action: #selector(refreshAllProviders), keyEquivalent: "r")
        refreshAll.keyEquivalentModifierMask = [.command, .shift]
        refreshAll.target = self

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        return main
    }

    private func tagItem(_ title: String, _ action: Selector, _ key: String,
                         _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Launch" {
            for item in menu.items where item.action == #selector(togglePin) {
                item.title = (store.selectedItem.map(store.isPinned) ?? false) ? "Unpin Model" : "Pin Model"
            }
        }
        if menu.title == "Client" {
            for (index, item) in menu.items.enumerated() {
                item.state = ProviderKind.allCases[index] == store.client ? .on : .off
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addProvider):
            return presentedSheet == nil
        case #selector(launchModel):
            return presentedSheet == nil && store.canLaunch && !workspace.isLaunching
        case #selector(chooseWorkdir), #selector(showScript), #selector(copyScript):
            return true
        case #selector(togglePin), #selector(setContextWindow):
            return store.selectedItem != nil
        case #selector(refreshActive), #selector(refreshVisible):
            return true
        case #selector(refreshAll), #selector(refreshAllProviders):
            return !store.providers.isEmpty
        case #selector(editProvider), #selector(removeProvider):
            return presentedSheet == nil && workspace.activeProvider != nil
        case #selector(selectClient(_:)):
            return true
        case #selector(openSettings), #selector(toggleSidebar):
            return true
        case #selector(closeWindow):
            guard let key = NSApp.keyWindow else { return false }
            return key.sheetParent != nil || key === mainWindow
        default:
            return true
        }
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store, workspace: workspace)
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleSidebar() {
        windowController?.toggleSidebar(nil)
    }

    @objc func closeWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key.sheetParent != nil {
            key.performClose(nil)
        } else if key === mainWindow {
            key.performClose(nil)
        }
    }

    @objc func addProvider() { workspace.addProvider() }
    @objc func launchModel() { workspace.launch() }
    @objc func chooseWorkdir() { workspace.chooseWorkdir() }
    @objc func togglePin() {
        if let item = store.selectedItem { store.togglePin(item) }
    }
    @objc func setContextWindow() {
        if let item = store.selectedItem { workspace.beginEditingWindow(item) }
    }
    @objc func copyScript() { workspace.copyScript() }
    @objc func showScript() { workspace.isShowingScript = true }
    @objc func refreshActive() { workspace.refreshVisible() }
    @objc func refreshAll() { workspace.refreshAll() }
    @objc func refreshVisible() { workspace.refreshVisible() }
    @objc func refreshAllProviders() { workspace.refreshAll() }
    @objc func goLibrary() { workspace.destination = .library }
    @objc func goPinned() { workspace.destination = .pinned }
    @objc func goRecents() { workspace.destination = .recents }
    @objc func goOverview() { workspace.destination = .overview }
    @objc func goUsage() { workspace.destination = .usage }
    @objc func goAccounts() { workspace.destination = .accounts }
    @objc func goModels() { workspace.destination = .providersPage }
    @objc func goPricing() { workspace.destination = .pricing }
    @objc func editProvider() {
        guard presentedSheet == nil, let provider = workspace.activeProvider else { return }
        workspace.edit(provider)
    }
    @objc func removeProvider() {
        guard presentedSheet == nil, let provider = workspace.activeProvider else { return }
        workspace.confirmRemoval(of: provider)
    }
    @objc func selectClient(_ sender: NSMenuItem) {
        store.client = ProviderKind.allCases[sender.tag]
    }
}
