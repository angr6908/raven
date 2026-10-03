import AppKit

struct RowAction {
    let symbol: String
    let label: String
    var help: String? = nil
    var destructive: Bool = false
    let run: () -> Void
}

@MainActor
final class PanelColumn {
    enum Kind {
        case label, attributed, control, toggle, actions, rate
    }

    let title: String
    let width: CGFloat
    let alignsRight: Bool
    let isMono: Bool
    let value: (Int) -> String
    let attributed: ((Int) -> NSAttributedString?)?
    let tooltip: ((Int) -> String?)?
    let control: ((Int) -> NSView?)?
    let sort: ((Int, Int) -> Bool)?
    let toggleState: ((Int) -> Bool)?
    let toggleEnabled: ((Int) -> Bool)?
    let onToggle: ((Int, Bool) -> Void)?
    let rowActions: ((Int) -> [RowAction])?
    let rateValue: ((Int) -> Double?)?
    let rateCommit: ((Int, Double?) -> Void)?

    var kind: Kind {
        if onToggle != nil { return .toggle }
        if rowActions != nil { return .actions }
        if rateCommit != nil { return .rate }
        if control != nil { return .control }
        if attributed != nil { return .attributed }
        return .label
    }

    init(title: String,
         width: CGFloat,
         alignsRight: Bool = false,
         isMono: Bool = false,
         value: @escaping (Int) -> String,
         attributed: ((Int) -> NSAttributedString?)? = nil,
         tooltip: ((Int) -> String?)? = nil,
         control: ((Int) -> NSView?)? = nil,
         sort: ((Int, Int) -> Bool)? = nil) {
        self.title = title
        self.width = width
        self.alignsRight = alignsRight
        self.isMono = isMono
        self.value = value
        self.attributed = attributed
        self.tooltip = tooltip
        self.control = control
        self.sort = sort
        self.toggleState = nil
        self.toggleEnabled = nil
        self.onToggle = nil
        self.rowActions = nil
        self.rateValue = nil
        self.rateCommit = nil
    }

    private init(title: String,
                 width: CGFloat,
                 alignsRight: Bool,
                 isMono: Bool,
                 toggleState: ((Int) -> Bool)?,
                 toggleEnabled: ((Int) -> Bool)?,
                 onToggle: ((Int, Bool) -> Void)?,
                 tooltip: ((Int) -> String?)?) {
        self.title = title
        self.width = width
        self.alignsRight = alignsRight
        self.isMono = isMono
        self.value = { _ in "" }
        self.attributed = nil
        self.tooltip = tooltip
        self.control = nil
        self.sort = nil
        self.toggleState = toggleState
        self.toggleEnabled = toggleEnabled
        self.onToggle = onToggle
        self.rowActions = nil
        self.rateValue = nil
        self.rateCommit = nil
    }

    private init(title: String,
                 width: CGFloat,
                 rowActions: @escaping (Int) -> [RowAction]) {
        self.title = title
        self.width = width
        self.alignsRight = false
        self.isMono = false
        self.value = { _ in "" }
        self.attributed = nil
        self.tooltip = nil
        self.control = nil
        self.sort = nil
        self.toggleState = nil
        self.toggleEnabled = nil
        self.onToggle = nil
        self.rowActions = rowActions
        self.rateValue = nil
        self.rateCommit = nil
    }

    private init(title: String,
                 width: CGFloat,
                 rateValue: @escaping (Int) -> Double?,
                 rateCommit: @escaping (Int, Double?) -> Void) {
        self.title = title
        self.width = width
        self.alignsRight = true
        self.isMono = true
        self.value = { row in
            guard let number = rateValue(row) else { return "—" }
            return PanelFormats.rate(number)
        }
        self.attributed = nil
        self.tooltip = nil
        self.control = nil
        self.sort = nil
        self.toggleState = nil
        self.toggleEnabled = nil
        self.onToggle = nil
        self.rowActions = nil
        self.rateValue = rateValue
        self.rateCommit = rateCommit
    }

    static func byText(_ key: @escaping (Int) -> String) -> (Int, Int) -> Bool {
        { a, b in key(a).localizedCompare(key(b)) == .orderedAscending }
    }

    static func byNumber(_ key: @escaping (Int) -> Double) -> (Int, Int) -> Bool {
        { a, b in key(a) < key(b) }
    }

    static func text(title: String, width: CGFloat, alignsRight: Bool = false, mono: Bool = false,
                     value: @escaping (Int) -> String,
                     sort: ((Int, Int) -> Bool)? = nil,
                     tooltip: ((Int) -> String?)? = nil) -> PanelColumn {
        PanelColumn(title: title, width: width, alignsRight: alignsRight, isMono: mono,
                    value: value, tooltip: tooltip, sort: sort)
    }

    static func rich(title: String, width: CGFloat, alignsRight: Bool = false,
                     attributed: @escaping (Int) -> NSAttributedString?,
                     sort: ((Int, Int) -> Bool)? = nil,
                     tooltip: ((Int) -> String?)? = nil) -> PanelColumn {
        PanelColumn(title: title, width: width, alignsRight: alignsRight, value: { _ in "" },
                    attributed: attributed, tooltip: tooltip, sort: sort)
    }

    static func toggle(title: String, width: CGFloat,
                       state: @escaping (Int) -> Bool,
                       enabled: ((Int) -> Bool)? = nil,
                       tooltip: ((Int) -> String?)? = nil,
                       action: @escaping (Int, Bool) -> Void) -> PanelColumn {
        PanelColumn(title: title, width: width, alignsRight: false, isMono: false,
                    toggleState: state, toggleEnabled: enabled, onToggle: action, tooltip: tooltip)
    }

    static func actions(title: String, width: CGFloat,
                        rowActions: @escaping (Int) -> [RowAction]) -> PanelColumn {
        PanelColumn(title: title, width: width, rowActions: rowActions)
    }

    static func rate(title: String, width: CGFloat,
                     value: @escaping (Int) -> Double?,
                     commit: @escaping (Int, Double?) -> Void) -> PanelColumn {
        PanelColumn(title: title, width: width, rateValue: value, rateCommit: commit)
    }
}

@MainActor
final class LabelCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ text: String, column: PanelColumn, tooltip: String?) {
        guard let field = textField else { return }
        field.stringValue = text
        field.alignment = column.alignsRight ? .right : .left
        field.font = column.isMono
            ? RavenType.mono(ofSize: 11)
            : (column.alignsRight ? RavenType.numeric(ofSize: 11) : .systemFont(ofSize: 11))
        toolTip = tooltip
    }
}

@MainActor
final class AttributedCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ text: NSAttributedString, column: PanelColumn, tooltip: String?) {
        guard let field = textField else { return }
        field.attributedStringValue = text
        field.alignment = column.alignsRight ? .right : .left
        toolTip = tooltip
    }
}

@MainActor
final class ToggleCell: NSTableCellView {
    private let toggle = NSSwitch()
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        NSLayoutConstraint.activate([
            toggle.centerXAnchor.constraint(equalTo: centerXAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(on: Bool, enabled: Bool, tooltip: String?, columnTitle: String, handler: @escaping (Bool) -> Void) {
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        toggle.toolTip = tooltip
        toggle.setAccessibilityLabel(columnTitle)
        onToggle = handler
    }

    @objc private func toggled(_ sender: NSSwitch) {
        onToggle?(sender.state == .on)
    }
}

@MainActor
final class ActionsCell: NSTableCellView {
    private let row = NSStackView()
    private var actions: [RowAction] = []

    init() {
        super.init(frame: .zero)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ actions: [RowAction]) {
        self.actions = actions
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in actions.enumerated() {
            let button = AppKitTheme.iconButton(symbol: action.symbol,
                                                tooltip: action.help ?? action.label,
                                                tint: action.destructive ? .systemRed : .secondaryLabelColor,
                                                accessibilityLabel: action.label,
                                                action: #selector(pressed(_:)),
                                                target: self)
            button.identifier = NSUserInterfaceItemIdentifier("\(index)")
            button.controlSize = .mini
            row.addArrangedSubview(button)
        }
        row.isHidden = actions.isEmpty
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let index = Int(raw),
              index < actions.count else { return }
        actions[index].run()
    }
}

@MainActor
final class RateCell: NSTableCellView, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    var commit: ((Double?) -> Void)?
    private var baseline: Double?

    init() {
        super.init(frame: .zero)
        field.font = RavenType.numeric(ofSize: 11)
        field.alignment = .right
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(committed)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(value: Double?, tooltip: String?, columnTitle: String, handler: @escaping (Double?) -> Void) {
        baseline = value
        field.placeholderString = "—"
        field.stringValue = value.map { PanelFormats.rate($0) } ?? ""
        field.toolTip = tooltip
        field.setAccessibilityLabel(columnTitle)
        commit = handler
    }

    @objc private func committed() {
        finishEdit()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEdit()
    }

    private func finishEdit() {
        guard let commit else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let parsed = text.isEmpty ? nil : Double(text)
        if parsed != baseline {
            self.commit = nil
            commit(parsed)
        }
    }
}

@MainActor
final class ControlCell: NSTableCellView {
    private var hosted: NSView?

    func bind(_ view: NSView?, tooltip: String?) {
        hosted?.removeFromSuperview()
        toolTip = tooltip
        guard let view else {
            hosted = nil
            return
        }
        hosted = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

@MainActor
final class FooterRowView: NSTableRowView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        wantsLayer = true
        let line = CALayer()
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        line.backgroundColor = NSColor.separatorColor.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers = [line]
        CATransaction.commit()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

@MainActor
final class PanelReadTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let searchField = NSSearchField()

    var maxContentHeight: CGFloat = 420 {
        didSet { syncHeight() }
    }
    var minContentHeight: CGFloat = 88 {
        didSet { syncHeight() }
    }
    var accessibilityName: String? {
        didSet { tableView.setAccessibilityLabel(accessibilityName) }
    }
    var columnAutoresizing: NSTableView.ColumnAutoresizingStyle {
        get { tableView.columnAutoresizingStyle }
        set { tableView.columnAutoresizingStyle = newValue }
    }

    var emptyMessage: String? = "No results."
    var rowContextMenu: ((Int) -> NSMenu?)?
    var doubleAction: ((Int) -> Void)?
    var searchText: ((Int) -> String)? {
        didSet { syncSearchVisibility() }
    }
    var showsSearchControl = false {
        didSet { syncSearchVisibility() }
    }
    var searchPlaceholder: String? {
        didSet { searchField.placeholderString = searchPlaceholder ?? "Search…" }
    }
    var autoSortFirstSortableColumn = true
    var initialSortColumn: Int? {
        didSet {
            guard let initialSortColumn, panelColumns.indices.contains(initialSortColumn) else { return }
            pendingSort = (initialSortColumn, initialSortAscending)
        }
    }
    var initialSortAscending = true
    var paginationEnabled = false {
        didSet { paginationBar.isHidden = !paginationEnabled || (hidePaginationOnSinglePage && order.count <= pageSize) }
    }
    var hidePaginationOnSinglePage = false
    var pageSizes: [Int] = [15, 30, 50]
    var footerProvider: (() -> [NSAttributedString?]?)? {
        didSet {
            footerCells = nil
            syncSearchVisibility()
        }
    }

    var contentWidth: CGFloat {
        tableView.tableColumns.reduce(0) { $0 + $1.width }
    }

    private let contentStack = NSStackView()
    private let searchRow = NSStackView()
    private let paginationBar = NSStackView()
    private let paginationLabel = AppKitTheme.label("", font: .systemFont(ofSize: 11),
                                                    color: .secondaryLabelColor)
    private let pageSizePopUp = NSPopUpButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let pageButtons = NSStackView()
    private let emptyLabel = AppKitTheme.label("", font: .systemFont(ofSize: 12),
                                               color: .secondaryLabelColor)
    private var scrollHeightConstraint: NSLayoutConstraint?

    private var panelColumns: [PanelColumn] = []
    private var order: [Int] = []
    private var snapshot: [Int] = []
    private var footerCells: [NSAttributedString?]?
    private var dataCount = 0
    private var sortColumn: Int?
    private var sortAscending = true
    private var restoredSort = false
    private var pendingSort: (column: Int, ascending: Bool)?
    private var autoSortSuppressed = false
    private var page = 0
    private var pageSize = 15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.rowHeight = RavenMetrics.tableRowHeight
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)

        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        searchRow.isHidden = true
        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        searchField.placeholderString = "Search…"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.searchMinWidth).isActive = true
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: RavenMetrics.searchMaxWidth).isActive = true
        searchField.setAccessibilityLabel("Filter rows")
        searchRow.addArrangedSubview(searchSpacer)
        searchRow.addArrangedSubview(searchField)

        buildPaginationBar()

        contentStack.addArrangedSubview(searchRow)
        contentStack.addArrangedSubview(scrollView)
        contentStack.addArrangedSubview(paginationBar)

        let height = scrollView.heightAnchor.constraint(equalToConstant: 120)
        height.priority = .defaultHigh
        height.isActive = true
        scrollHeightConstraint = height

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildPaginationBar() {
        paginationBar.orientation = .horizontal
        paginationBar.alignment = .centerY
        paginationBar.spacing = 8
        paginationBar.isHidden = true

        paginationLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        pageSizePopUp.controlSize = .small
        pageSizePopUp.font = .systemFont(ofSize: 11)
        pageSizePopUp.target = self
        pageSizePopUp.action = #selector(pageSizeChanged)
        for size in pageSizes {
            pageSizePopUp.addItem(withTitle: "\(size) / page")
            pageSizePopUp.lastItem?.tag = size
        }
        pageSizePopUp.toolTip = "Rows per page"
        pageSizePopUp.setAccessibilityLabel("Rows per page")

        for (button, symbol, tooltip, action) in [
            (prevButton, "chevron.left", "Previous page", #selector(previousPage)),
            (nextButton, "chevron.right", "Next page", #selector(nextPage)),
        ] {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = tooltip
            button.target = self
            button.action = action
            button.setAccessibilityLabel(tooltip)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        }

        pageButtons.orientation = .horizontal
        pageButtons.alignment = .centerY
        pageButtons.spacing = 4

        paginationBar.addArrangedSubview(paginationLabel)
        paginationBar.addArrangedSubview(spacer)
        paginationBar.addArrangedSubview(pageSizePopUp)
        paginationBar.addArrangedSubview(prevButton)
        paginationBar.addArrangedSubview(pageButtons)
        paginationBar.addArrangedSubview(nextButton)
    }

    func configure(_ columns: [PanelColumn]) {
        let rebuilt = panelColumns.count != columns.count
            || zip(panelColumns, columns).contains {
                $0.title != $1.title || $0.width != $1.width || $0.kind != $1.kind
            }
        autoSortSuppressed = false
        panelColumns = columns
        if rebuilt || tableView.tableColumns.isEmpty {
            while let first = tableView.tableColumns.first {
                tableView.removeTableColumn(first)
            }
            for (index, column) in columns.enumerated() {
                let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
                item.width = column.width
                item.minWidth = min(column.width, 60)
                item.headerCell.title = column.title
                item.headerCell.alignment = column.alignsRight ? .right : .left
                item.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
                item.sortDescriptorPrototype = column.sort == nil
                    ? nil
                    : NSSortDescriptor(key: "col\(index)", ascending: true)
                tableView.addTableColumn(item)
            }
            if let sortColumn, sortColumn >= columns.count {
                self.sortColumn = nil
                tableView.sortDescriptors = []
            }
        }
        if !restoredSort {
            restoredSort = true
            let explicit = pendingSort.flatMap { columns.indices.contains($0.column) ? $0 : nil }
            if let pending = explicit {
                applySort(column: pending.column, ascending: pending.ascending)
            } else if autoSortFirstSortableColumn, let index = columns.firstIndex(where: { $0.sort != nil }) {
                applySort(column: index, ascending: true)
            } else {
                autoSortSuppressed = true
            }
        } else if let pending = pendingSort, columns.indices.contains(pending.column) {
            applySort(column: pending.column, ascending: pending.ascending)
        }
    }

    private func applySort(column: Int, ascending: Bool) {
        pendingSort = nil
        sortColumn = column
        sortAscending = ascending
        let descriptor = NSSortDescriptor(key: "col\(column)", ascending: ascending)
        tableView.sortDescriptors = [descriptor]
        guard tableView.tableColumns.indices.contains(column) else { return }
        tableView.setIndicatorImage(NSImage(systemSymbolName: ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill",
                                            accessibilityDescription: nil),
                                    in: tableView.tableColumns[column])
        tableView.highlightedTableColumn = tableView.tableColumns[column]
    }

    func reload(rowCount: Int) {
        dataCount = rowCount
        rebuild(resetPage: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot.count + (footerCells != nil ? 1 : 0)
    }

    private var footerRow: Int { snapshot.count }

    private func modelRow(_ viewRow: Int) -> Int? {
        guard viewRow >= 0, viewRow < snapshot.count else { return nil }
        return snapshot[viewRow]
    }

    private func columnID(_ tableColumn: NSTableColumn?) -> Int? {
        guard let raw = tableColumn?.identifier.rawValue, raw.hasPrefix("col"),
              let index = Int(raw.dropFirst(3)), index < panelColumns.count else { return nil }
        return index
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = columnID(tableColumn) else { return nil }
        let column = panelColumns[index]

        if row == footerRow {
            guard let cells = footerCells, index < cells.count, let text = cells[index] else {
                return nil
            }
            let cell = dequeue("raven.cell.attributed", in: tableView) { AttributedCell() }
            cell.bind(text, column: column, tooltip: nil)
            return cell
        }

        guard let model = modelRow(row) else { return nil }
        switch column.kind {
        case .toggle:
            let cell = dequeue("raven.cell.toggle", in: tableView) { ToggleCell() }
            cell.bind(on: column.toggleState?(model) ?? false,
                      enabled: column.toggleEnabled?(model) ?? true,
                      tooltip: column.tooltip?(model),
                      columnTitle: column.title) { [column] enabled in
                column.onToggle?(model, enabled)
            }
            return cell
        case .actions:
            let cell = dequeue("raven.cell.actions", in: tableView) { ActionsCell() }
            cell.bind(column.rowActions?(model) ?? [])
            return cell
        case .rate:
            let cell = dequeue("raven.cell.rate", in: tableView) { RateCell() }
            cell.bind(value: column.rateValue?(model),
                      tooltip: column.tooltip?(model),
                      columnTitle: column.title) { [column] number in
                column.rateCommit?(model, number)
            }
            return cell
        case .control:
            let cell = dequeue("raven.cell.control", in: tableView) { ControlCell() }
            cell.bind(column.control?(model), tooltip: column.tooltip?(model))
            return cell
        case .attributed:
            if let text = column.attributed?(model) {
                let cell = dequeue("raven.cell.attributed", in: tableView) { AttributedCell() }
                cell.bind(text, column: column, tooltip: column.tooltip?(model))
                return cell
            }
            let fallback = dequeue("raven.cell.label", in: tableView) { LabelCell() }
            fallback.bind(column.value(model), column: column, tooltip: column.tooltip?(model))
            return fallback
        case .label:
            let cell = dequeue("raven.cell.label", in: tableView) { LabelCell() }
            cell.bind(column.value(model), column: column, tooltip: column.tooltip?(model))
            return cell
        }
    }

    private func dequeue<T: NSView>(_ id: String, in tableView: NSTableView, make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? T {
            return reused
        }
        let created = make()
        created.identifier = identifier
        return created
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if row == footerRow {
            return FooterRowView()
        }
        let rowView = NSTableRowView()
        if let model = modelRow(row), let menu = rowContextMenu?(model) {
            rowView.menu = menu
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row != footerRow
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key,
              raw.hasPrefix("col"),
              let index = Int(raw.dropFirst(3)),
              index < panelColumns.count,
              panelColumns[index].sort != nil else {
            sortColumn = nil
            rebuild(resetPage: true)
            return
        }
        sortColumn = index
        sortAscending = descriptor.ascending
        rebuild(resetPage: true)
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func setSearchQuery(_ value: String) {
        guard searchField.stringValue != value else { return }
        searchField.stringValue = value
        rebuild(resetPage: true)
    }

    private func syncSearchVisibility() {
        searchRow.isHidden = !(showsSearchControl && searchText != nil)
    }

    @objc private func searchChanged() {
        rebuild(resetPage: true)
    }

    @objc private func pageSizeChanged() {
        pageSize = pageSizePopUp.selectedItem?.tag ?? pageSizes.first ?? 15
        rebuild(resetPage: true)
    }

    @objc private func previousPage() {
        guard page > 0 else { return }
        page -= 1
        rebuild(resetPage: false)
    }

    @objc private func nextPage() {
        page += 1
        rebuild(resetPage: false)
    }

    @objc private func pageButtonPressed(_ sender: NSButton) {
        page = max(0, sender.tag - 1)
        rebuild(resetPage: false)
    }

    private func rebuild(resetPage: Bool) {
        if resetPage { page = 0 }
        var indices = Array(0..<dataCount)
        if let searchText {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            if !query.isEmpty {
                indices = indices.filter { searchText($0).lowercased().contains(query) }
            }
        }
        if !autoSortSuppressed, let sortColumn, sortColumn < panelColumns.count,
           let compare = panelColumns[sortColumn].sort {
            indices.sort { a, b in
                if sortAscending {
                    if compare(a, b) { return true }
                    if compare(b, a) { return false }
                } else {
                    if compare(b, a) { return true }
                    if compare(a, b) { return false }
                }
                return a < b
            }
        }
        order = indices

        let pages = max(1, Int(ceil(Double(order.count) / Double(pageSize))))
        if page >= pages { page = pages - 1 }
        if page < 0 { page = 0 }

        if paginationEnabled {
            let start = page * pageSize
            let end = min(order.count, start + pageSize)
            snapshot = start < end ? Array(order[start..<end]) : []
        } else {
            snapshot = order
        }

        if let footerProvider {
            footerCells = footerProvider()
        } else {
            footerCells = nil
        }

        tableView.reloadData()
        let empty = snapshot.isEmpty
        emptyLabel.stringValue = emptyMessage ?? ""
        emptyLabel.isHidden = !(empty && emptyMessage != nil)
        updatePagination(total: order.count, pages: pages)
        syncHeight()
    }

    private func syncHeight() {
        let rowPitch = tableView.rowHeight + tableView.intercellSpacing.height
        var desired = tableView.headerView?.frame.height ?? 24
        desired += CGFloat(snapshot.count) * rowPitch + 4
        if footerCells != nil { desired += rowPitch }
        if !searchRow.isHidden { desired += searchRow.fittingSize.height + contentStack.spacing }
        if !paginationBar.isHidden { desired += paginationBar.fittingSize.height + contentStack.spacing }
        desired = min(max(desired, minContentHeight), maxContentHeight)
        scrollHeightConstraint?.constant = desired
    }

    private func updatePagination(total: Int, pages: Int) {
        guard paginationEnabled else {
            paginationBar.isHidden = true
            return
        }
        paginationBar.isHidden = hidePaginationOnSinglePage && total <= pageSize
        paginationLabel.stringValue = "\(total) row\(total == 1 ? "" : "s")"
        if let item = pageSizePopUp.itemArray.first(where: { $0.tag == pageSize }) {
            pageSizePopUp.select(item)
        }
        prevButton.isEnabled = page > 0
        nextButton.isEnabled = page < pages - 1

        pageButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in Self.pageItems(page: page, pages: pages) {
            guard let number = item else {
                pageButtons.addArrangedSubview(AppKitTheme.label("…", font: RavenType.numeric(ofSize: 11),
                                                                 color: .secondaryLabelColor))
                continue
            }
            let button = NSButton(title: "\(number)", target: self, action: #selector(pageButtonPressed(_:)))
            button.tag = number
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = RavenType.numeric(ofSize: 11)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            if number - 1 == page {
                button.contentTintColor = .controlAccentColor
            } else {
                button.contentTintColor = .secondaryLabelColor
            }
            button.setAccessibilityLabel("Page \(number)")
            pageButtons.addArrangedSubview(button)
        }
    }

    private static func pageItems(page: Int, pages: Int) -> [Int?] {
        if pages <= 7 {
            return (1...pages).map { $0 }
        }
        let current = page + 1
        let wanted = Set([1, pages, current - 1, current, current + 1].filter { $0 >= 1 && $0 <= pages })
        var items: [Int?] = []
        var previous = 0
        for number in wanted.sorted() {
            if number - previous > 1 { items.append(nil) }
            items.append(number)
            previous = number
        }
        return items
    }

    @objc private func rowClicked() {}

    @objc private func rowDoubleClicked() {
        guard let model = modelRow(tableView.clickedRow) else { return }
        doubleAction?(model)
    }
}

nonisolated enum PanelText {
    static func dash() -> String { "—" }

    static func strong(_ text: String, suffix: String? = nil, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if let suffix {
            result.append(NSAttributedString(string: " · \(suffix)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
            ]))
        }
        return result
    }

    static func main(_ text: String, _ suffix: String?, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        if let suffix {
            result.append(NSAttributedString(string: " · \(suffix)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
            ]))
        }
        return result
    }

    static func badge(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: " \(text) ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
            .backgroundColor: color.withAlphaComponent(0.12),
            .paragraphStyle: paragraph,
        ])
    }

    static func softBadge(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: " \(text) ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.35),
            .paragraphStyle: paragraph,
        ])
    }

    static func quotaValue(percent: String, reset: String?, fraction: Double? = nil) -> NSAttributedString {
        let percentColor: NSColor
        if let fraction {
            switch fraction {
            case ..<0.6: percentColor = .systemGreen
            case ..<0.85: percentColor = .systemYellow
            default: percentColor = .systemRed
            }
        } else {
            percentColor = .labelColor
        }
        let result = NSMutableAttributedString(string: percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: percentColor,
        ])
        if let reset {
            let clock = NSTextAttachment()
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            clock.bounds = NSRect(x: 0, y: -1, width: 10, height: 10)
            result.append(NSAttributedString(attachment: clock))
            result.append(NSAttributedString(string: " \(reset)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }
}
