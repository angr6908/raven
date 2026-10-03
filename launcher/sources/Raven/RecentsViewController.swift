import AppKit

@MainActor
final class RecentsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var recents: [RecentLaunch] = []
    private var stateView: NSView?

    override func loadView() {
        view = NSView()

        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 40
        tableView.style = .inset
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let clearButton = AppKitTheme.glassButton(title: "Clear", symbol: "trash", prominent: false,
                                                  action: #selector(clearRecents), target: self)
        clearButton.toolTip = "Forget every recent launch"
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clearButton)
        self.clearButton = clearButton

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            clearButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -RavenMetrics.spacing5),
            clearButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: RavenMetrics.spacing2),
        ])
    }

    private var clearButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
        tracker.start { [weak self] in
            self?.rebuild()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func rebuild() {
        clearButton.isEnabled = !store.recents.isEmpty
        if store.recents.isEmpty {
            showState(UnavailableView(symbol: "clock",
                                      title: "No launches yet",
                                      description: "Every model you launch shows up here so you can pick up where you left off."))
            return
        }
        let visible = workspace.visibleRecents
        if visible.isEmpty {
            showState(UnavailableView(symbol: "magnifyingglass",
                                      title: "No matches",
                                      description: "No launches match “\(workspace.search)”."))
            return
        }
        hideState()
        recents = visible
        tableView.reloadData()
    }

    private func showState(_ state: NSView) {
        hideState()
        scrollView.isHidden = true
        state.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(state)
        NSLayoutConstraint.activate([
            state.topAnchor.constraint(equalTo: view.topAnchor),
            state.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            state.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        stateView = state
    }

    private func hideState() {
        stateView?.removeFromSuperview()
        stateView = nil
        scrollView.isHidden = false
    }

    @objc private func clearRecents() {
        store.clearRecents()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        RecentRowView(recent: recents[row], store: store, workspace: workspace)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        let recent = recents[row]
        let menu = NSMenu()
        let again = NSMenuItem(title: "Launch Again", action: #selector(menuLaunchAgain(_:)), keyEquivalent: "")
        again.target = self
        let restore = NSMenuItem(title: "Restore Selection", action: #selector(menuRestore(_:)), keyEquivalent: "")
        restore.target = self
        let copy = NSMenuItem(title: "Copy Model ID", action: #selector(menuCopyID(_:)), keyEquivalent: "")
        copy.target = self
        for item in [again, restore, copy] {
            item.representedObject = recent
            menu.addItem(item)
        }
        menu.insertItem(.separator(), at: 2)
        rowView.menu = menu
        return rowView
    }

    private func selected(_ sender: NSMenuItem) -> RecentLaunch? { sender.representedObject as? RecentLaunch }

    @objc private func menuLaunchAgain(_ sender: NSMenuItem) {
        if let recent = selected(sender) { workspace.relaunch(recent) }
    }

    @objc private func menuRestore(_ sender: NSMenuItem) {
        if let recent = selected(sender) { workspace.restore(recent) }
    }

    @objc private func menuCopyID(_ sender: NSMenuItem) {
        if let recent = selected(sender) { workspace.copy(recent.modelID) }
    }
}

@MainActor
final class RecentRowView: NSTableCellView {
    init(recent: RecentLaunch, store: ProviderStore, workspace: Workspace) {
        super.init(frame: .zero)
        toolTip = recent.workdir

        let provider = store.provider(id: recent.providerID)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: recent.client.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        icon.contentTintColor = provider.map(AppKitTheme.providerAccent) ?? .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let title = AppKitTheme.label(recent.modelID, font: RavenType.mono(ofSize: 13), color: .labelColor, lineLimit: 1)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = AppKitTheme.label("\(provider?.name ?? "Removed provider") · \(recent.client.displayName) · \(recent.folderName)",
                                       font: RavenType.caption(), color: .secondaryLabelColor, lineLimit: 1)
        let textStack = NSStackView(views: [title, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        textField = title

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let date = AppKitTheme.label(formatter.localizedString(for: recent.date, relativeTo: Date()),
                                     font: RavenType.caption(), color: .secondaryLabelColor)
        date.translatesAutoresizingMaskIntoConstraints = false
        addSubview(date)

        let launchButton = NSButton(title: "", target: nil, action: nil)
        launchButton.isBordered = false
        launchButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        launchButton.contentTintColor = .controlAccentColor
        launchButton.imagePosition = .imageOnly
        launchButton.toolTip = "Launch this again"
        launchButton.translatesAutoresizingMaskIntoConstraints = false
        launchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        launchButton.heightAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        launchButton.isEnabled = provider != nil && !workspace.isLaunching
        let handler = RecentLaunchHandler(recent: recent, workspace: workspace)
        launchButton.target = handler
        launchButton.action = #selector(RecentLaunchHandler.launch)
        addSubview(launchButton)
        self.launchHandler = handler

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            date.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 10),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
            launchButton.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 8),
            launchButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            launchButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var launchHandler: RecentLaunchHandler?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class RecentLaunchHandler: NSObject {
    private let recent: RecentLaunch
    private let workspace: Workspace

    init(recent: RecentLaunch, workspace: Workspace) {
        self.recent = recent
        self.workspace = workspace
    }

    @objc func launch() {
        workspace.relaunch(recent)
    }
}
