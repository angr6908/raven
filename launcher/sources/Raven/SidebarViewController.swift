import AppKit

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [SidebarRow] = []

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        view = effect

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.allowsColumnReordering = false
        tableView.floatsGroupRows = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 180
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.registerForDraggedTypes([Self.dragType])

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    static let dragType = NSPasteboard.PasteboardType("raven.provider.index")

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.providers.count
            _ = self.store.pinned.count
            _ = self.store.recents.count
            _ = self.store.modelCount
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

    func reload() {
        var next: [SidebarRow] = [.header("Library")]
        next.append(.item(.library, "All Models", store.modelCount))
        next.append(.item(.pinned, "Pinned", store.pinned.count))
        next.append(.item(.recents, "Recents", store.recents.count))
        next.append(.header("Providers"))
        for provider in store.providers {
            next.append(.provider(provider, store.status(of: provider)))
        }
        next.append(.header("Panel"))
        next.append(.item(.overview, "Overview", nil))
        next.append(.item(.usage, "Usage", nil))
        next.append(.item(.accounts, "Accounts", nil))
        next.append(.item(.providersPage, "Models", nil))
        next.append(.item(.pricing, "Pricing", nil))
        rows = next
        tableView.reloadData()
        if let index = rows.firstIndex(where: { $0.destination == workspace.destination }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func row(at index: Int) -> SidebarRow? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard let entry = self.row(at: row) else { return false }
        if case .header = entry { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let entry = self.row(at: row) else { return 30 }
        if case .header = entry { return 24 }
        return 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = self.row(at: row) else { return nil }
        switch entry {
        case .header(let title):
            if title == "Providers" {
                return providersHeader()
            }
            return AppKitTheme.sectionHeader(title)
        case .item(let destination, let title, let badge):
            let cell = SidebarRowView.dequeue(from: tableView)
            cell.bind(symbol: destination.symbol, color: nil,
                      title: title, badge: badge.map(String.init), warning: false)
            return cell
        case .provider(let provider, let status):
            let badge: String?
            switch status {
            case .ready(let count): badge = String(count)
            default: badge = nil
            }
            let cell = SidebarRowView.dequeue(from: tableView)
            cell.bind(symbol: "server.rack", color: AppKitTheme.providerAccent(provider),
                      title: provider.name, badge: badge, warning: status.isFailure)
            cell.toolTip = "\(provider.host) · \(status.subtitle)"
            return cell
        }
    }

    private func providersHeader() -> NSView {
        let container = NSView()
        let title = AppKitTheme.sectionHeader("Providers")
        title.translatesAutoresizingMaskIntoConstraints = false
        let addButton = NSButton(title: "", target: self, action: #selector(addProvider))
        addButton.isBordered = false
        addButton.controlSize = .small
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Provider")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "Add a provider (⌘N)"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(addButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 22),
            addButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        return container
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let entry = self.row(at: row) else { return nil }
        switch entry {
        case .header(let title): return title
        case .item(_, let title, _): return title
        case .provider(let provider, _): return provider.name
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        if let entry = self.row(at: row), case .provider(let provider, _) = entry {
            let menu = NSMenu()
            let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshRowProvider(_:)), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = provider.id.uuidString
            let edit = NSMenuItem(title: "Edit…", action: #selector(editRowProvider(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = provider.id.uuidString
            let remove = NSMenuItem(title: "Remove…", action: #selector(removeRowProvider(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = provider.id.uuidString
            menu.items = [refresh, edit, .separator(), remove]
            rowView.menu = menu
        }
        return rowView
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let destination = rows[row].destination else { return }
        workspace.destination = destination
    }

    private func providerFromMenuItem(_ sender: NSMenuItem) -> Provider? {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return nil }
        return store.provider(id: id)
    }

    @objc private func refreshRowProvider(_ sender: NSMenuItem) {
        if let provider = providerFromMenuItem(sender) { workspace.refresh(provider) }
    }

    @objc private func editRowProvider(_ sender: NSMenuItem) {
        if let provider = providerFromMenuItem(sender) { workspace.edit(provider) }
    }

    @objc private func removeRowProvider(_ sender: NSMenuItem) {
        if let provider = providerFromMenuItem(sender) { workspace.confirmRemoval(of: provider) }
    }

    @objc private func addProvider() {
        workspace.addProvider()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let entry = self.row(at: row), case .provider = entry else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, row >= 0, row < rows.count else { return [] }
        guard case .provider = rows[row] else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let source = Int(raw),
              case .provider(let dragged, _) = self.row(at: source) ?? .header(""),
              case .provider(let target, _) = self.row(at: row) ?? .header("") else { return false }
        guard let from = store.providers.firstIndex(where: { $0.id == dragged.id }),
              let to = store.providers.firstIndex(where: { $0.id == target.id }) else { return false }
        store.moveProviders(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        reload()
        return true
    }
}

enum SidebarRow {
    case header(String)
    case item(Destination, String, Int?)
    case provider(Provider, ProviderStatus)

    var destination: Destination? {
        switch self {
        case .item(let destination, _, _): destination
        case .provider(let provider, _): .provider(provider.id)
        case .header: nil
        }
    }
}

@MainActor
final class SidebarRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-row")

    private let icon = NSImageView()
    private let warningIcon = NSImageView()
    private let badgeLabel: PillLabel
    private var plainTrailing: NSLayoutConstraint!
    private var badgeTrailing: NSLayoutConstraint!
    private var warningTrailing: NSLayoutConstraint!

    static func dequeue(from tableView: NSTableView) -> SidebarRowView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarRowView {
            return reused
        }
        let view = SidebarRowView()
        view.identifier = identifier
        return view
    }

    private init() {
        badgeLabel = AppKitTheme.pill("", color: .secondaryLabelColor)
        super.init(frame: .zero)

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = AppKitTheme.label("", font: .systemFont(ofSize: 13),
                                      color: .labelColor, lineLimit: 1, flexible: true)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        warningIcon.contentTintColor = .systemRed
        warningIcon.translatesAutoresizingMaskIntoConstraints = false
        warningIcon.isHidden = true
        addSubview(warningIcon)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        plainTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        badgeTrailing = label.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -6)
        warningTrailing = label.trailingAnchor.constraint(lessThanOrEqualTo: warningIcon.leadingAnchor, constant: -6)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            warningIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningIcon.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            warningIcon.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        plainTrailing.isActive = true
    }

    func bind(symbol: String, color: NSColor?, title: String, badge: String?, warning: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color ?? .secondaryLabelColor
        textField?.stringValue = title
        setAccessibilityLabel(title)
        toolTip = nil

        warningIcon.isHidden = !warning
        badgeLabel.isHidden = warning || badge == nil
        if let badge, !warning {
            badgeLabel.stringValue = badge
        }
        plainTrailing.isActive = !warning && badge == nil
        badgeTrailing.isActive = !warning && badge != nil
        warningTrailing.isActive = warning
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
