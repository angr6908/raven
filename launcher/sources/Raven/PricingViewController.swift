import AppKit

@MainActor
final class PricingViewController: PanelScrollViewController, NSSearchFieldDelegate {
    private let store = PricingStore.shared
    private let tracker = ObservationTracker()

    private let notice = PanelNoticeView()
    private var card: GlassCardView!
    private var rowsStack: NSStackView!
    private let emptyLabel = AppKitTheme.label("", font: .systemFont(ofSize: 12),
                                               color: .secondaryLabelColor, lineLimit: 1)
    private var searchField: NSSearchField!
    private var fetchAllButton: NSButton!
    private var sweepButton: NSButton!
    private var footerLabel: NSTextField!
    private var loader: NSView!

    private var expanded = Set<String>()
    private var fetching = Set<String>()
    private var fetchingAll = false
    private var fetchNote: String?
    private var sortKey = "model"
    private var sortAscending = true
    private var sortButtons: [String: NSButton] = [:]

    private weak var activeField: NSTextField?
    private var pendingRender = false

    private var actions: [Int: @MainActor () -> Void] = [:]
    private var actionToken = 0
    private var rateTargets: [ObjectIdentifier: (String, String)] = [:]
    private var windowTargets: [ObjectIdentifier: (String, Int, Int)] = [:]

    private let chevronWidth: CGFloat = 18
    private let rateWidth: CGFloat = 74
    private let peakWidth: CGFloat = 54
    private let fetchWidth: CGFloat = 26
    private let trashWidth: CGFloat = 26

    override func loadView() {
        super.loadView()

        addFullWidth(notice)

        loader = CenteredLoaderView(message: "Loading prices…")
        loader.heightAnchor.constraint(equalToConstant: 160).isActive = true
        loader.isHidden = true
        addFullWidth(loader)

        buildCard()
        addFullWidth(card)

        footerLabel = AppKitTheme.label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, lineLimit: 1)
        addFullWidth(footerLabel)
    }

    private func buildCard() {
        card = AppKitTheme.glassCard()

        let title = AppKitTheme.label("Model prices", font: .systemFont(ofSize: 14, weight: .semibold),
                                       color: .labelColor, lineLimit: 1)
        title.setContentHuggingPriority(.required, for: .horizontal)

        searchField = NSSearchField()
        searchField.placeholderString = "Filter models…"
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self

        let header = NSStackView(views: [title, SpacerView(), searchField])
        header.orientation = .horizontal
        header.spacing = 10

        fetchAllButton = iconButton("cloud.download", color: .secondaryLabelColor,
                                    action: #selector(fetchAllPressed),
                                    help: "Fetch all prices from models.dev")
        fetchAllButton.widthAnchor.constraint(equalToConstant: fetchWidth).isActive = true
        sweepButton = iconButton("broom", color: .secondaryLabelColor,
                                 action: #selector(sweepPressed),
                                 help: "Remove all unused price rows")
        sweepButton.widthAnchor.constraint(equalToConstant: trashWidth).isActive = true

        let columnHeader = NSStackView(views: [
            fixedSpacer(chevronWidth),
            sortButton("Model", key: "model", width: 0, flexible: true),
            sortButton("Input $/M", key: "input", width: rateWidth),
            sortButton("Output $/M", key: "output", width: rateWidth),
            sortButton("Cached $/M", key: "cached", width: rateWidth),
            sortButton("Peak", key: "peak", width: peakWidth),
            fetchAllButton,
            sweepButton,
        ])
        columnHeader.orientation = .horizontal
        columnHeader.spacing = 8
        columnHeader.alignment = .centerY
        updateSortIndicators()

        let separator = NSBox()
        separator.boxType = .separator

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 5

        emptyLabel.isHidden = true
        let shell = NSStackView(views: [header, columnHeader, separator, rowsStack, emptyLabel])
        shell.orientation = .vertical
        shell.alignment = .leading
        shell.spacing = 10
        shell.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: card.content.topAnchor, constant: 14),
            shell.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 16),
            shell.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -16),
            shell.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: shell.widthAnchor),
            columnHeader.widthAnchor.constraint(equalTo: shell.widthAnchor),
            separator.widthAnchor.constraint(equalTo: shell.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: shell.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: shell.widthAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.prices
            _ = self.store.recordModels
            _ = self.store.loading
            _ = self.store.error
            _ = self.store.saver.status
            self.scheduleRender()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        store.refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func scheduleRender() {
        guard activeField == nil else {
            pendingRender = true
            return
        }
        render()
    }

    private func render() {
        let saveFailure: String?
        switch store.saver.status {
        case .failed(let message): saveFailure = message
        default: saveFailure = nil
        }
        notice.show(store.error ?? saveFailure)

        loader.isHidden = !store.loading
        card.isHidden = store.loading
        footerLabel.isHidden = store.loading
        guard !store.loading else { return }

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.removeAll()
        rateTargets.removeAll()
        windowTargets.removeAll()

        let all = store.rows().sorted { a, b in
            if sortKey == "model" {
                let order = a.model.localizedCompare(b.model)
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
            let left = sortValue(a)
            let right = sortValue(b)
            if left == right { return a.model.localizedCompare(b.model) == .orderedAscending }
            return sortAscending ? left < right : left > right
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = all.filter { query.isEmpty || $0.model.lowercased().contains(query) }
        for row in visible {
            for view in rowViews(for: row) {
                view.translatesAutoresizingMaskIntoConstraints = false
                rowsStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        emptyLabel.isHidden = !visible.isEmpty
        if visible.isEmpty {
            emptyLabel.stringValue = all.isEmpty ? "No prices yet." : "No results."
        }
        sweepButton.isHidden = all.filter { !$0.inLog }.isEmpty
        fetchAllButton.isEnabled = !fetchingAll
        fetchAllButton.image = AppKitTheme.symbol("cloud.download",
                                                  color: fetchingAll ? .controlAccentColor : .secondaryLabelColor,
                                                  pointSize: 11)

        renderFooter(all)
    }

    private func renderFooter(_ rows: [PricingRowData]) {
        if let fetchNote {
            footerLabel.stringValue = fetchNote
            footerLabel.textColor = .secondaryLabelColor
            return
        }
        switch store.saver.status {
        case .saving:
            footerLabel.stringValue = "Saving…"
            footerLabel.textColor = .secondaryLabelColor
        case .saved:
            footerLabel.stringValue = "Saved — costs updated."
            footerLabel.textColor = .secondaryLabelColor
        case .failed:
            footerLabel.stringValue = "Save failed."
            footerLabel.textColor = .systemRed
        case .idle:
            let unpriced = rows.filter { !$0.priced && $0.inLog }.count
            if unpriced > 0 {
                footerLabel.stringValue = "\(unpriced) model\(unpriced == 1 ? "" : "s") in use without prices"
            } else {
                footerLabel.stringValue = "all used models priced"
            }
            footerLabel.textColor = .secondaryLabelColor
        }
    }

    private func rowViews(for row: PricingRowData) -> [NSView] {
        var views = [mainRow(for: row)]
        if row.peak && expanded.contains(row.model) {
            views.append(expandedRow(for: row))
        }
        return views
    }

    private func mainRow(for row: PricingRowData) -> NSView {
        let chevron: NSView
        if row.peak {
            let open = expanded.contains(row.model)
            let button = iconButton(open ? "chevron.down" : "chevron.right",
                                    color: .secondaryLabelColor.withAlphaComponent(0.7),
                                    action: #selector(rowActionPressed(_:)),
                                    help: "\(open ? "Hide" : "Edit") peak pricing for \(row.model)")
            button.widthAnchor.constraint(equalToConstant: chevronWidth).isActive = true
            bind(button) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(row.model) {
                    self.expanded.remove(row.model)
                } else {
                    self.expanded.insert(row.model)
                }
                self.render()
            }
            chevron = button
        } else {
            chevron = fixedSpacer(chevronWidth)
        }

        let nameLabel = AppKitTheme.label(row.model,
                                          font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                          color: (!row.priced && row.inLog) ? .systemOrange : .labelColor,
                                          lineLimit: 1)
        nameLabel.toolTip = row.model
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            chevron,
            nameLabel,
            rateField(model: row.model, price: row.price, field: "input"),
            rateField(model: row.model, price: row.price, field: "output"),
            rateField(model: row.model, price: row.price, field: "cached"),
            peakCell(model: row.model, peak: row.peak),
            fetchCell(model: row.model),
            row.inLog ? fixedSpacer(trashWidth) : trashCell(model: row.model),
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func expandedRow(for row: PricingRowData) -> NSView {
        let label = AppKitTheme.label("Peak windows UTC",
                                      font: .systemFont(ofSize: 10, weight: .medium),
                                      color: .secondaryLabelColor, lineLimit: 1)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var chips: [NSView] = []
        let windows = row.price.peakWindows ?? []
        for (index, window) in windows.enumerated() {
            let start = window.count > 0 ? window[0] : 1
            let end = window.count > 1 ? window[1] : 4
            chips.append(hourField(model: row.model, index: index, pos: 0, value: start))
            chips.append(AppKitTheme.label("–", font: .systemFont(ofSize: 10),
                                           color: .secondaryLabelColor, lineLimit: 1))
            chips.append(hourField(model: row.model, index: index, pos: 1, value: end))
            let remove = iconButton("xmark", color: .secondaryLabelColor.withAlphaComponent(0.7),
                                    action: #selector(rowActionPressed(_:)),
                                    help: "Remove peak window \(index + 1) for \(row.model)")
            bind(remove) { [weak self] in
                self?.store.removeWindow(row.model, index: index)
            }
            chips.append(remove)
        }

        let plus = iconButton("plus", color: .secondaryLabelColor.withAlphaComponent(0.7),
                              action: #selector(rowActionPressed(_:)),
                              help: "Add peak window for \(row.model)")
        bind(plus) { [weak self] in
            self?.store.addWindow(row.model)
        }

        let inset = fixedSpacer(20)
        let chipRow = NSStackView(views: chips + [plus])
        chipRow.orientation = .horizontal
        chipRow.spacing = 3
        chipRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            inset,
            label,
            chipRow,
            SpacerView(),
            rateField(model: row.model, price: row.price, field: "input_peak"),
            rateField(model: row.model, price: row.price, field: "output_peak"),
            rateField(model: row.model, price: row.price, field: "cached_peak"),
            fixedSpacer(peakWidth),
            fixedSpacer(fetchWidth),
            fixedSpacer(trashWidth),
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func rateField(model: String, price: ModelPrice, field: String) -> NSTextField {
        let value: Double
        switch field {
        case "input": value = price.input
        case "output": value = price.output
        case "cached": value = price.cached
        case "input_peak": value = price.inputPeak ?? 0
        case "output_peak": value = price.outputPeak ?? 0
        default: value = price.cachedPeak ?? 0
        }
        let textField = NSTextField(string: PanelFormats.rate(value))
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textField.alignment = .right
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("rate")
        textField.widthAnchor.constraint(equalToConstant: rateWidth).isActive = true
        textField.toolTip = "\(field) price per 1M tokens for \(model)"
        rateTargets[ObjectIdentifier(textField)] = (model, field)
        return textField
    }

    private func hourField(model: String, index: Int, pos: Int, value: Int) -> NSTextField {
        let textField = NSTextField(string: String(value))
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textField.alignment = .center
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("hour")
        textField.widthAnchor.constraint(equalToConstant: 30).isActive = true
        textField.toolTip = "Peak \(pos == 0 ? "start" : "end") hour \(index + 1) for \(model)"
        windowTargets[ObjectIdentifier(textField)] = (model, index, pos)
        return textField
    }

    private func peakCell(model: String, peak: Bool) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = peak ? .on : .off
        toggle.target = self
        toggle.action = #selector(rowActionPressed(_:))
        toggle.toolTip = "Peak pricing \(peak ? "on" : "off") for \(model)"
        bind(toggle) { [weak self] in
            guard let self else { return }
            let on = toggle.state == .on
            self.store.togglePeak(model, on: on)
            if on {
                self.expanded.insert(model)
            } else {
                self.expanded.remove(model)
            }
        }
        let holder = NSStackView(views: [SpacerView(), toggle])
        holder.orientation = .horizontal
        holder.spacing = 0
        holder.widthAnchor.constraint(equalToConstant: peakWidth).isActive = true
        return holder
    }

    private func fetchCell(model: String) -> NSView {
        let busy = fetching.contains(model) || fetchingAll
        let button = iconButton("cloud.download",
                                color: busy ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.7),
                                action: #selector(rowActionPressed(_:)),
                                help: "Fetch price from models.dev")
        button.isEnabled = !busy
        button.widthAnchor.constraint(equalToConstant: fetchWidth).isActive = true
        bind(button) { [weak self] in
            self?.startFetch(model)
        }
        let holder = NSStackView(views: [button])
        holder.orientation = .horizontal
        holder.widthAnchor.constraint(equalToConstant: fetchWidth).isActive = true
        return holder
    }

    private func trashCell(model: String) -> NSView {
        let button = iconButton("trash", color: .systemRed.withAlphaComponent(0.8),
                                action: #selector(rowActionPressed(_:)),
                                help: "Remove price for \(model)")
        button.widthAnchor.constraint(equalToConstant: trashWidth).isActive = true
        bind(button) { [weak self] in
            guard let self else { return }
            self.expanded.remove(model)
            self.store.removeModel(model)
        }
        let holder = NSStackView(views: [button])
        holder.orientation = .horizontal
        holder.widthAnchor.constraint(equalToConstant: trashWidth).isActive = true
        return holder
    }

    private func bind(_ control: NSControl, _ action: @escaping @MainActor () -> Void) {
        actionToken += 1
        control.tag = actionToken
        actions[actionToken] = action
    }

    @objc private func rowActionPressed(_ sender: NSControl) {
        actions[sender.tag]?()
    }

    @objc private func fetchAllPressed() {
        let models = store.rows().map(\.model)
        guard !models.isEmpty, !fetchingAll else { return }
        fetchingAll = true
        fetchNote = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.store.fetchAll(models)
            self.fetchingAll = false
            var parts = ["\(outcome.priced) priced"]
            if outcome.empty > 0 { parts.append("\(outcome.empty) not on models.dev") }
            if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
            self.fetchNote = "Fetched \(models.count) models from models.dev — \(parts.joined(separator: ", "))."
            self.scheduleRender()
        }
    }

    @objc private func sweepPressed() {
        store.sweepDeletable(store.rows().filter { !$0.inLog }.map(\.model))
        expanded.removeAll()
    }

    private func startFetch(_ model: String) {
        guard !fetching.contains(model), !fetchingAll else { return }
        fetching.insert(model)
        fetchNote = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.store.fetchPrice(model)
            self.fetching.remove(model)
            self.scheduleRender()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === searchField else { return }
        render()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        activeField = field
        editingBaseline[ObjectIdentifier(field)] = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === activeField { activeField = nil }
        let baseline = editingBaseline.removeValue(forKey: ObjectIdentifier(field))
        if let role = field.identifier?.rawValue {
            let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            switch role {
            case "rate":
                guard raw != baseline else { break }
                if let (model, rateField) = rateTargets[ObjectIdentifier(field)] {
                    store.setRate(model, field: rateField, value: Double(raw) ?? 0)
                }
            case "hour":
                guard raw != baseline else { break }
                if let (model, index, pos) = windowTargets[ObjectIdentifier(field)] {
                    let value = Double(raw).map { Int($0) }
                    store.editWindow(model, index: index, pos: pos,
                                     value: value.map { min(23, max(0, $0)) })
                }
            default:
                break
            }
        }
        if pendingRender {
            pendingRender = false
            render()
        }
    }

    private var editingBaseline: [ObjectIdentifier: String] = [:]

    private func iconButton(_ symbol: String, color: NSColor, action: Selector, help: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.contentTintColor = color
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = help
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        return button
    }

    private func columnHeaderLabel(_ text: String, width: CGFloat, flexible: Bool = false) -> NSTextField {
        let label = AppKitTheme.label(text, font: .systemFont(ofSize: 11, weight: .medium),
                                      color: .secondaryLabelColor, lineLimit: 1)
        if flexible {
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return label
    }

    private func sortButton(_ text: String, key: String, width: CGFloat, flexible: Bool = false) -> NSButton {
        let button = NSButton(title: text, target: self, action: #selector(sortPressed(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.toolTip = "Sort by \(text)"
        if flexible {
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.alignment = .left
        } else {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.alignment = .right
        }
        sortButtons[key] = button
        return button
    }

    @objc private func sortPressed(_ sender: NSButton) {
        guard let key = sortButtons.first(where: { $0.value === sender })?.key else { return }
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        updateSortIndicators()
        render()
    }

    private func updateSortIndicators() {
        for (buttonKey, button) in sortButtons {
            button.image = NSImage(systemSymbolName: buttonKey == sortKey
                                   ? (sortAscending ? "chevron.up" : "chevron.down")
                                   : "chevron.up.chevron.down",
                                   accessibilityDescription: nil)
        }
    }

    private func sortValue(_ row: PricingRowData) -> Double {
        switch sortKey {
        case "peak": return PanelLogic.hasPeak(row.price) ? 1 : 0
        case "input": return row.price.input
        case "output": return row.price.output
        case "cached": return row.price.cached
        default: return 0
        }
    }

    private func fixedSpacer(_ width: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: width).isActive = true
        spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return spacer
    }
}
