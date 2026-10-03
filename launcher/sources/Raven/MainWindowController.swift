import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let split: RootSplitViewController

    private static let toggleID = NSToolbarItem.Identifier("raven.toggleSidebar")
    private static let separatorID = NSToolbarItem.Identifier("raven.trackingSeparator")
    private static let searchID = NSToolbarItem.Identifier("raven.search")
    private static let refreshID = NSToolbarItem.Identifier("raven.refresh")
    private static let healthID = NSToolbarItem.Identifier("raven.health")
    private var refreshStack: NSStackView?
    private var refreshButton: NSButton?
    private var refreshSpinner: NSProgressIndicator?
    private var searchItem: NSSearchToolbarItem?
    private var healthItem: NSToolbarItem?
    private var healthPill: PillLabel?
    private var proxyVersion: String?
    private let healthTracker = ObservationTracker()

    init() {
        let rootSplit = RootSplitViewController()
        split = rootSplit
        let window = NSWindow(contentViewController: rootSplit)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.title = "Raven"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.setFrameAutosaveName("RavenMain")
        if window.frame.width < 800 {
            window.setContentSize(NSSize(width: 1020, height: 660))
            window.center()
        }
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        let toolbar = NSToolbar(identifier: "RavenMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        healthTracker.start { [weak self] in
            guard let self, let pill = self.healthPill else { return }
            let live = UsageStore.shared.isLive
            let up = UsageStore.shared.isProxyUp
            let degraded = live && UsageStore.shared.droppedRecords > 0
            pill.stringValue = degraded ? "proxy · stale" : (live ? "proxy · live" : (up ? "proxy" : "offline"))
            let tint: NSColor = degraded ? .systemYellow : (live ? .systemGreen : (up ? .secondaryLabelColor : .systemRed))
            pill.textColor = tint
            pill.baseColor = tint
            if degraded {
                pill.toolTip = "Live feed degraded — counts reflect the last full snapshot"
            } else if let version = self.proxyVersion {
                pill.toolTip = "proxy ok · v\(version)"
            } else {
                pill.toolTip = up ? "proxy ok" : "proxy unreachable"
            }
            if let spinner = self.refreshSpinner, let button = self.refreshButton {
                let refreshing = self.store.isRefreshing
                spinner.isHidden = !refreshing
                button.isHidden = refreshing
                if refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            }
            self.syncSearchPlaceholder()
        }
        Task { [weak self] in
            guard let health = try? await PanelClient.shared.get("/api/health") as HealthResponse else { return }
            self?.proxyVersion = health.version
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleID, Self.separatorID, .flexibleSpace, Self.healthID, Self.searchID, Self.refreshID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toggleID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Toggle Sidebar"
            item.paletteLabel = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.leading",
                                 accessibilityDescription: "Toggle Sidebar")
                ?? NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            item.isBordered = true
            item.toolTip = "Toggle Sidebar"
            return item
        case Self.separatorID:
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier,
                                                  splitView: split.splitView,
                                                  dividerIndex: 0)
        case Self.searchID:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search models"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.toolTip = "Search models"
            searchItem = item
            return item
        case Self.refreshID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise",
                                                 accessibilityDescription: "Refresh") ?? NSImage(),
                                  target: self,
                                  action: #selector(refreshTapped))
            button.bezelStyle = .glass
            button.imagePosition = .imageOnly
            button.controlSize = .regular
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.isHidden = true
            let stack = NSStackView(views: [button, spinner])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            refreshStack = stack
            refreshButton = button
            refreshSpinner = spinner
            item.view = stack
            item.toolTip = "Refresh this view (⌘R)"
            return item
        case Self.healthID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let pill = AppKitTheme.pill("…", color: .secondaryLabelColor)
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            item.view = pill
            item.toolTip = "Raven proxy status"
            healthItem = item
            healthPill = pill
            return item
        default:
            return nil
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        workspace.search = sender.stringValue
        searchItem?.searchField.placeholderString = workspace.searchPlaceholder
    }

    @objc func toggleSidebar(_ sender: Any?) {
        split.toggleSidebar(sender)
    }

    @objc private func refreshTapped() {
        workspace.refreshVisible()
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.refreshID {
            return !store.isRefreshing
        }
        return true
    }

    func syncSearchPlaceholder() {
        searchItem?.searchField.placeholderString = workspace.searchPlaceholder
    }

    func setSidebarFocused() {
        searchItem?.searchField.resignFirstResponder()
    }
}
