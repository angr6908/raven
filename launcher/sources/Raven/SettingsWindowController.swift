import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: ProviderStore
    private let workspace: Workspace

    init(store: ProviderStore, workspace: Workspace) {
        self.store = store
        self.workspace = workspace

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let launchItem = NSTabViewItem(viewController: SettingsFormViewController())
        launchItem.label = "Launch"
        launchItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        let providerItem = NSTabViewItem(viewController: SettingsProviderViewController())
        providerItem.label = "Providers"
        providerItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        tabs.tabViewItems = [launchItem, providerItem]

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.titlebarSeparatorStyle = .automatic
        window.setContentSize(NSSize(width: 480, height: 320))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class SettingsFormViewController: NSViewController {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let clientControl = NSSegmentedControl()
    private let folderButton = NSButton()
    private let recentClearButton = NSButton()
    private let windowResetButton = NSButton()

    override func loadView() {
        let root = NSView()

        for (index, kind) in ProviderKind.allCases.enumerated() {
            clientControl.setLabel(kind.displayName, forSegment: index)
            clientControl.setWidth(0, forSegment: index)
        }
        clientControl.segmentCount = ProviderKind.allCases.count
        if #available(macOS 27.0, *) {
            clientControl.role = .valueSelection
        }
        clientControl.trackingMode = .selectOne
        clientControl.target = self
        clientControl.action = #selector(clientChanged(_:))

        folderButton.bezelStyle = .rounded
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderButton.imagePosition = .imageLeading
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)

        recentClearButton.title = "Clear"
        recentClearButton.bezelStyle = .rounded
        recentClearButton.controlSize = .small
        recentClearButton.target = self
        recentClearButton.action = #selector(clearRecents)

        windowResetButton.title = "Reset All"
        windowResetButton.bezelStyle = .rounded
        windowResetButton.controlSize = .small
        windowResetButton.target = self
        windowResetButton.action = #selector(resetWindows)

        let showConfigButton = NSButton(title: "Show in Finder", target: self, action: #selector(showConfig))
        showConfigButton.bezelStyle = .rounded
        showConfigButton.controlSize = .small

        let footer = AppKitTheme.label(
            "Providers, keys and preferences live in \(ProviderStore.configFile.path(percentEncoded: false)).",
            font: RavenType.caption(), color: .secondaryLabelColor)
        footer.maximumNumberOfLines = 0
        footer.lineBreakMode = .byWordWrapping

        let grid = NSGridView(views: [
            [AppKitTheme.label("Client", font: RavenType.body(), color: .labelColor), clientControl],
            [AppKitTheme.label("Folder", font: RavenType.body(), color: .labelColor), folderButton],
            [AppKitTheme.label("Recent launches", font: RavenType.body(), color: .labelColor), recentClearButton],
            [AppKitTheme.label("Context window overrides", font: RavenType.body(), color: .labelColor), windowResetButton],
            [AppKitTheme.label("Configuration file", font: RavenType.body(), color: .labelColor), showConfigButton],
        ])
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.rowSpacing = RavenMetrics.spacing3
        grid.columnSpacing = RavenMetrics.spacing3

        let rows = NSStackView(views: [grid, footer])
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = RavenMetrics.spacing4
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: root.topAnchor, constant: RavenMetrics.spacing5),
            rows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: RavenMetrics.spacing5),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -RavenMetrics.spacing5),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sync()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.client
            _ = self.store.workdir
            _ = self.store.recents.count
            _ = self.store.windowOverrides.count
            self.sync()
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

    private func sync() {
        clientControl.selectedSegment = ProviderKind.allCases.firstIndex(of: store.client) ?? 0
        folderButton.title = store.workdirLabel
        folderButton.toolTip = store.workdirPath
        recentClearButton.isEnabled = !store.recents.isEmpty
        windowResetButton.isEnabled = !store.windowOverrides.isEmpty
    }

    @objc private func clientChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < ProviderKind.allCases.count else { return }
        store.client = ProviderKind.allCases[index]
    }

    @objc private func chooseFolder() {
        workspace.chooseWorkdir()
    }

    @objc private func clearRecents() {
        store.clearRecents()
    }

    @objc private func resetWindows() {
        store.clearWindowOverrides()
    }

    @objc private func showConfig() {
        workspace.revealConfig()
    }
}

@MainActor
final class SettingsProviderViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let addButton = NSButton()
    private var rows: [Provider] = []

    override func loadView() {
        let root = NSView()

        addButton.title = "Add Provider"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Provider")
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addProvider)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(addButton)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 44
        tableView.style = .inset
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsMultipleSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Providers")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.providers.count
            for provider in self.store.providers {
                _ = self.store.status(of: provider)
            }
            self.reload()
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

    private func reload() {
        rows = store.providers
        tableView.reloadData()
    }

    @objc private func addProvider() {
        workspace.addProvider()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let reused = tableView.makeView(withIdentifier: ProviderSettingsRowView.identifier, owner: self)
            as? ProviderSettingsRowView
        let view = reused ?? ProviderSettingsRowView()
        view.identifier = ProviderSettingsRowView.identifier
        let provider = rows[row]
        view.bind(provider: provider,
                  status: store.status(of: provider),
                  onEdit: { [weak workspace] in workspace?.edit(provider) },
                  onRemove: { [weak workspace] in workspace?.confirmRemoval(of: provider) })
        return view
    }
}

@MainActor
final class ProviderSettingsRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("provider-row")

    private let detailLabel = AppKitTheme.label("", font: .systemFont(ofSize: 11),
                                                color: .secondaryLabelColor, lineLimit: 1, flexible: true)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private var onEdit: (() -> Void)?
    private var onRemove: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = AppKitTheme.label("", font: .systemFont(ofSize: 13),
                                      color: .labelColor, lineLimit: 1, flexible: true)
        textField = title

        let textStack = NSStackView(views: [title, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(editTapped)

        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove provider")
        removeButton.imagePosition = .imageOnly
        removeButton.toolTip = "Remove provider"
        removeButton.setAccessibilityLabel("Remove provider")
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        let buttons = NSStackView(views: [editButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(provider: Provider,
              status: ProviderStatus,
              onEdit: @escaping () -> Void,
              onRemove: @escaping () -> Void) {
        self.onEdit = onEdit
        self.onRemove = onRemove
        textField?.stringValue = provider.name
        detailLabel.stringValue = "\(provider.rootURL) · \(status.subtitle)"
        setAccessibilityLabel("\(provider.name), \(status.subtitle)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEdit = nil
        onRemove = nil
    }

    @objc private func editTapped() { onEdit?() }

    @objc private func removeTapped() { onRemove?() }
}
