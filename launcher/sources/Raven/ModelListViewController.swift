import AppKit

@MainActor
final class ModelListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [ModelRow] = []
    private var stateView: NSView?
    private var syncingSelection = false

    override func loadView() {
        view = NSView()

        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.allowsColumnReordering = false
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 30
        tableView.style = .inset
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

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

    func rebuild() {
        if let provider = workspace.focusedProvider, let message = store.error(for: provider) {
            showState(ProviderErrorView(provider: provider,
                                         message: message,
                                         onRetry: { [weak self] in self?.workspace.refresh(provider) },
                                         onEdit: { [weak self] in self?.workspace.edit(provider) }))
            return
        }
        if store.isRefreshing && store.modelCount == 0 {
            showState(CenteredLoaderView(message: "Loading models…"))
            return
        }
        if workspace.isSearching && workspace.isEmptyResult {
            showState(UnavailableView(symbol: "magnifyingglass",
                                      title: "No matches",
                                      description: "No models match “\(workspace.search)”."))
            return
        }
        if workspace.isEmptyResult {
            showState(makeStateView(emptyDestinationView))
            return
        }
        hideState()

        var next: [ModelRow] = []
        for section in workspace.sections {
            switch section.kind {
            case .provider(let provider):
                next.append(.header(provider.name, AppKitTheme.providerAccent(provider), section.items.count))
            case .owner(let owner):
                next.append(.header(owner, nil, section.items.count))
            }
            for item in section.items {
                next.append(.item(item))
            }
        }
        let changed = next.map(\.signature) != rows.map(\.signature)
        rows = next
        if changed {
            tableView.reloadData()
        } else {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                                 columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
        syncSelection()
    }

    private func syncSelection() {
        guard let ref = store.selection,
              let index = rows.firstIndex(where: { if case .item(let item) = $0 { return item.ref == ref } else { return false } })
        else {
            if store.selection == nil, tableView.selectedRow != -1 {
                syncingSelection = true
                tableView.deselectAll(nil)
                syncingSelection = false
            }
            return
        }
        if tableView.selectedRow != index {
            syncingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            syncingSelection = false
        }
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
        handlers = [:]
        handlerOwner = nil
        scrollView.isHidden = false
    }

    private func emptyDestinationView(_ controller: ModelListViewController) -> NSView {
        switch workspace.destination {
        case .pinned:
            return UnavailableView(symbol: "pin",
                                   title: "No pinned models",
                                   description: "Pin the models you reach for most and they'll collect here.")
        case .provider(let id):
            let name = store.provider(id: id)?.name ?? "This provider"
            return UnavailableView(symbol: "tray",
                                   title: "No models",
                                   description: "\(name) returned an empty model list.",
                                   actions: [controller.glassAction("Refresh", symbol: "arrow.clockwise", prominent: false) { [weak self] in
                                       if let provider = self?.store.provider(id: id) { self?.workspace.refresh(provider) }
                                   }])
        default:
            return UnavailableView(symbol: "tray",
                                   title: "No models",
                                   description: "None of your providers returned any models.",
                                   actions: [controller.glassAction("Refresh All", symbol: "arrow.clockwise", prominent: false) { [weak self] in
                                       self?.workspace.refreshAll()
                                   }])
        }
    }

    private func glassAction(_ title: String, symbol: String, prominent: Bool, handler: @escaping () -> Void) -> NSButton {
        let button = AppKitTheme.glassButton(title: title, symbol: symbol, prominent: prominent,
                                             action: #selector(stateButtonPressed(_:)), target: self)
        handlers[ObjectIdentifier(button)] = handler
        return button
    }

    private func makeStateView(_ build: (ModelListViewController) -> NSView) -> NSView {
        handlers = [:]
        handlerOwner = nil
        let state = build(self)
        adoptHandlers(from: state)
        return state
    }

    private var handlers: [ObjectIdentifier: () -> Void] = [:]
    private weak var handlerOwner: NSView?

    @objc private func stateButtonPressed(_ sender: NSButton) {
        handlers[ObjectIdentifier(sender)]?()
    }

    private func adoptHandlers(from state: NSView) {
        if handlerOwner !== state {
            handlers = [:]
            handlerOwner = state
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 32 }
        if case .header = rows[row] { return 24 }
        return 32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title, let accent, let count):
            return ModelHeaderView(title: title, accentSymbol: accent == nil ? nil : "server.rack",
                                   accent: accent, count: count)
        case .item(let item):
            return ModelRowView(item: item, store: store)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return rowView }
        rowView.menu = itemMenu(for: item, row: row)
        return rowView
    }

    private func itemMenu(for item: ModelItem, row: Int) -> NSMenu {
        let menu = NSMenu()
        let index = NSNumber(value: row)
        let launch = NSMenuItem(title: "Launch \(store.client.displayName)",
                                action: #selector(menuLaunch(_:)), keyEquivalent: "")
        launch.target = self
        launch.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        launch.representedObject = index
        menu.addItem(launch)
        menu.addItem(.separator())
        let pinned = store.isPinned(item)
        let pin = NSMenuItem(title: pinned ? "Unpin" : "Pin",
                             action: #selector(menuPin(_:)), keyEquivalent: "")
        pin.target = self
        pin.image = NSImage(systemSymbolName: pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pin.representedObject = index
        menu.addItem(pin)
        let window = NSMenuItem(title: "Set Context Window…", action: #selector(menuWindow(_:)), keyEquivalent: "")
        window.target = self
        window.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        window.representedObject = index
        menu.addItem(window)
        if store.windowBadge(for: item).isOverride {
            let reported = NSMenuItem(title: "Use Reported Window", action: #selector(menuUseReported(_:)), keyEquivalent: "")
            reported.target = self
            reported.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            reported.representedObject = index
            menu.addItem(reported)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Model ID", action: #selector(menuCopyID(_:)), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil)
        copy.representedObject = index
        menu.addItem(copy)
        return menu
    }

    private func menuItem(_ sender: NSMenuItem) -> ModelItem? {
        guard let index = sender.representedObject as? NSNumber,
              index.intValue < rows.count,
              case .item(let item) = rows[index.intValue] else { return nil }
        return item
    }

    @objc private func menuLaunch(_ sender: NSMenuItem) {
        if let item = menuItem(sender) { workspace.launch(item) }
    }

    @objc private func menuPin(_ sender: NSMenuItem) {
        if let item = menuItem(sender) { store.togglePin(item) }
    }

    @objc private func menuWindow(_ sender: NSMenuItem) {
        if let item = menuItem(sender) { workspace.beginEditingWindow(item) }
    }

    @objc private func menuUseReported(_ sender: NSMenuItem) {
        if let item = menuItem(sender) { workspace.setWindow(item, tokens: nil) }
    }

    @objc private func menuCopyID(_ sender: NSMenuItem) {
        if let item = menuItem(sender) { workspace.copy(item.entry.modelID) }
    }

    @objc private func rowClicked() {
        guard !syncingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        store.selection = item.ref
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        workspace.launch(item)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item.entry.modelID
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rowClicked()
    }
}

enum ModelRow {
    case header(String, NSColor?, Int?)
    case item(ModelItem)

    var signature: String {
        switch self {
        case .header(let title, _, let count): "h:\(title):\(count ?? 0)"
        case .item(let item): "i:\(item.id)"
        }
    }
}

@MainActor
final class ModelHeaderView: NSTableCellView {
    init(title: String, accentSymbol: String?, accent: NSColor?, count: Int?) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if let accentSymbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: accentSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            icon.contentTintColor = accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(icon)
        }
        let label = AppKitTheme.label(title, font: .systemFont(ofSize: 11, weight: .semibold),
                                      color: .secondaryLabelColor, lineLimit: 1)
        stack.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(spacer)
        if let count {
            let badge = AppKitTheme.pill("\(count)", color: .secondaryLabelColor)
            stack.addArrangedSubview(badge)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class ModelRowView: NSTableCellView {
    init(item: ModelItem, store: ProviderStore) {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.entry.family.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        icon.contentTintColor = AppKitTheme.familyTint(item.entry.family)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = AppKitTheme.label(item.entry.modelID, font: RavenType.mono(ofSize: 13), color: .labelColor, lineLimit: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        var trailingViews: [NSView] = []

        if store.isPinned(item) {
            let pin = NSImageView()
            pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            pin.contentTintColor = .secondaryLabelColor
            pin.toolTip = "Pinned"
            pin.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pin)
            trailingViews.append(pin)
        }

        let badge = store.windowBadge(for: item)
        let badgeStack = NSStackView()
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 3
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        if badge.isOverride {
            let slider = NSImageView()
            slider.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            slider.contentTintColor = .controlAccentColor
            badgeStack.addArrangedSubview(slider)
        }
        let badgeLabel = AppKitTheme.label(badge.label,
                                           font: RavenType.numeric(ofSize: 11),
                                           color: badge.isOverride ? .controlAccentColor : .secondaryLabelColor)
        badgeStack.addArrangedSubview(badgeLabel)
        badgeStack.toolTip = badge.isOverride
            ? "Context window set by you — where the client's context bar fills and auto-compaction fires"
            : "Context window reported by the provider"
        addSubview(badgeStack)
        trailingViews.append(badgeStack)

        var trailingX = trailingAnchor
        var trailingConstant = -10.0
        for view in trailingViews.reversed() {
            NSLayoutConstraint.activate([
                view.trailingAnchor.constraint(equalTo: trailingX, constant: CGFloat(trailingConstant)),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            trailingX = view.leadingAnchor
            trailingConstant = -6
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingViews.last?.leadingAnchor ?? badgeStack.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class ProviderErrorView: NSView {
    private let onRetry: () -> Void
    private let onEdit: () -> Void

    init(provider: Provider, message: String, onRetry: @escaping () -> Void, onEdit: @escaping () -> Void) {
        self.onRetry = onRetry
        self.onEdit = onEdit
        super.init(frame: .zero)
        let retry = AppKitTheme.glassButton(title: "Try Again", symbol: "arrow.clockwise", prominent: true,
                                            action: #selector(retryPressed), target: self)
        let edit = AppKitTheme.glassButton(title: "Edit Provider…", symbol: nil, prominent: false,
                                           action: #selector(editPressed), target: self)
        let content = UnavailableView(symbol: "wifi.exclamationmark",
                                      title: "Couldn't reach \(provider.name)",
                                      description: "\(message)\n\(provider.modelsURL)",
                                      actions: [retry, edit])
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func retryPressed() { onRetry() }
    @objc private func editPressed() { onEdit() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
