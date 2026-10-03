import AppKit

@MainActor
final class ModelZoneView: NSView, NSTextFieldDelegate {
    var entryProvider: () -> ProviderEntry? = { nil }
    var aliasOwner: () -> String = { "" }
    var emptyHint = ""
    var fetchUpstream: (() async throws -> [UpstreamCatalogModel])?
    var presetEfforts: ((String) -> [String])?
    var onChange: (@escaping (ProviderEntry) -> ProviderEntry) -> Void = { _ in }

    private let store = ProvidersPanelStore.shared
    private let shell = NSStackView()

    private var upstream: [UpstreamCatalogModel] = []
    private var picked: Set<String> = []
    private var filter = ""
    private var fetchError: String?
    private var fetching = false
    private var fetchingRow: Set<Int> = []
    private var rowNotes: [Int: String] = [:]

    private weak var activeField: NSTextField?
    private var pendingRebuild = false

    private weak var selectedCountLabel: NSTextField?
    private weak var addSelectedButton: NSButton?
    private weak var fetchButton: NSButton?
    private var pickerColumns: NSStackView?
    private var pickerRowItems: [NSButton] = []

    init() {
        super.init(frame: .zero)
        shell.orientation = .vertical
        shell.alignment = .leading
        shell.spacing = 8
        shell.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shell)
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var entry: ProviderEntry? { entryProvider() }

    func rebuild() {
        guard activeField == nil else {
            pendingRebuild = true
            return
        }
        shell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let models = entry?.models ?? []
        let owner = aliasOwner().trimmingCharacters(in: .whitespaces)
        let smartAlias = !models.isEmpty && models.allSatisfy {
            $0.name.isEmpty || $0.alias == PanelLogic.smartAliasFor(modelName: $0.name, providerName: owner)
        }

        let titleLabel = AppKitTheme.label("Models (name → alias · context window · effort levels)",
                                           font: .systemFont(ofSize: 12, weight: .medium),
                                           color: .secondaryLabelColor)
        let aliasLabel = AppKitTheme.label("Smart alias", font: .systemFont(ofSize: 11),
                                          color: .secondaryLabelColor)
        let aliasSwitch = NSSwitch()
        aliasSwitch.state = smartAlias ? .on : .off
        aliasSwitch.controlSize = .small
        aliasSwitch.target = self
        aliasSwitch.action = #selector(smartAliasToggled(_:))
        aliasSwitch.isEnabled = !models.isEmpty && !owner.isEmpty
        aliasSwitch.toolTip = "Alias = model name without vendor prefix, plus @provider"
        let aliasRow = NSStackView(views: [aliasLabel, aliasSwitch])
        aliasRow.orientation = .horizontal
        aliasRow.spacing = 6

        var controls: [NSView] = [aliasRow]
        if fetchUpstream != nil {
            let fetch = outlineButton(fetching ? "Fetching…" : "Fetch models")
            fetch.target = self
            fetch.action = #selector(runFetchPressed)
            fetch.isEnabled = !fetching
            fetchButton = fetch
            controls.append(fetch)
        } else {
            fetchButton = nil
        }
        let add = outlineButton("Add model", symbol: "plus")
        add.target = self
        add.action = #selector(addModelPressed)
        controls.append(add)

        let controlsStack = NSStackView(views: controls)
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 8
        let header = NSStackView(views: [titleLabel, SpacerView(), controlsStack])
        header.orientation = .horizontal
        header.spacing = 12
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        shell.addArrangedSubview(header)
        addWidth(header)

        if let fetchError {
            let error = AppKitTheme.label(fetchError, font: .systemFont(ofSize: 11), color: .systemRed)
            error.isSelectable = true
            shell.addArrangedSubview(error)
            addWidth(error)
        }

        if !upstream.isEmpty {
            let picker = pickerPanel()
            shell.addArrangedSubview(picker)
            addWidth(picker)
        }

        if models.isEmpty {
            let hint = AppKitTheme.label(emptyHint, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            hint.maximumNumberOfLines = 0
            hint.lineBreakMode = .byWordWrapping
            shell.addArrangedSubview(hint)
            addWidth(hint)
            invalidateIntrinsicContentSize()
            return
        }

        for (modelIndex, model) in models.enumerated() {
            let row = modelRow(modelIndex: modelIndex, model: model, smartAlias: smartAlias, owner: owner)
            shell.addArrangedSubview(row)
            addWidth(row)
        }
        invalidateIntrinsicContentSize()
    }

    private func addWidth(_ view: NSView) {
        view.widthAnchor.constraint(equalTo: shell.widthAnchor).isActive = true
    }

    private func outlineButton(_ title: String, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let symbol, let image = AppKitTheme.symbol(symbol, pointSize: 10) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func iconButton(_ symbol: String, color: NSColor, action: Selector, key: String) -> NSButton {
        let button = NSButton(image: AppKitTheme.symbol(symbol, color: color, pointSize: 11) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(key)
        return button
    }

    private func pickerPanel() -> NSView {
        let filter = NSTextField()
        filter.placeholderString = "Filter \(upstream.count) models…"
        filter.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        filter.controlSize = .small
        filter.delegate = self
        filter.identifier = NSUserInterfaceItemIdentifier("filter")
        filter.stringValue = self.filter
        filter.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let selectedCount = AppKitTheme.label("\(picked.count) selected",
                                              font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                              color: .secondaryLabelColor)
        selectedCountLabel = selectedCount
        let addSelected = NSButton(title: picked.isEmpty ? "Add selected" : "Add \(picked.count) selected",
                                   target: self, action: #selector(addSelectedPressed))
        addSelected.bezelStyle = .rounded
        addSelected.controlSize = .small
        addSelected.font = .systemFont(ofSize: 11)
        addSelected.isEnabled = !picked.isEmpty
        if let image = AppKitTheme.symbol("plus", pointSize: 10) {
            addSelected.image = image
            addSelected.imagePosition = .imageLeading
        }
        addSelectedButton = addSelected
        let close = iconButton("xmark", color: .secondaryLabelColor, action: #selector(closePickerPressed),
                               key: "picker-close")

        let topRow = NSStackView(views: [filter, SpacerView(), selectedCount, addSelected, close])
        topRow.orientation = .horizontal
        topRow.spacing = 8

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 16
        columns.translatesAutoresizingMaskIntoConstraints = false
        pickerColumns = columns
        buildPickerItems()
        layoutPickerColumns()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = columns
        columns.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let box = NSStackView(views: [topRow, scroll])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        topRow.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        scroll.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        return box
    }

    private func buildPickerItems() {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let existing = Set((entry?.models ?? []).map { $0.name.lowercased() })
        pickerRowItems = upstream.filter { model in
            term.isEmpty
                || model.id.lowercased().contains(term)
                || (model.displayName ?? "").lowercased().contains(term)
        }.map { model in
            let alreadyRouted = existing.contains(model.id.lowercased())
            let check = NSButton(checkboxWithTitle: model.displayName ?? model.id, target: self,
                                 action: #selector(pickToggled(_:)))
            check.controlSize = .small
            check.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            check.lineBreakMode = .byTruncatingTail
            check.identifier = NSUserInterfaceItemIdentifier(model.id)
            check.state = picked.contains(model.id) ? .on : .off
            let name = model.displayName ?? ""
            check.isEnabled = !alreadyRouted
            check.toolTip = alreadyRouted
                ? "Already added to this zone"
                : (name.isEmpty || name == model.id ? model.id : "\(name) (\(model.id))")
            return check
        }
    }

    private func layoutPickerColumns() {
        guard let columns = pickerColumns else { return }
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = bounds.width > 0 ? bounds.width : 700
        let count = width >= 900 ? 3 : (width >= 600 ? 2 : 1)
        let total = pickerRowItems.count
        guard total > 0 else { return }
        let perColumn = (total + count - 1) / count
        for index in 0..<count {
            let start = index * perColumn
            guard start < total else { break }
            let column = NSStackView(views: Array(pickerRowItems[start...].prefix(perColumn)))
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            columns.addArrangedSubview(column)
        }
    }

    private func updatePicker() {
        buildPickerItems()
        layoutPickerColumns()
        selectedCountLabel?.stringValue = "\(picked.count) selected"
        addSelectedButton?.title = picked.isEmpty ? "Add selected" : "Add \(picked.count) selected"
        addSelectedButton?.isEnabled = !picked.isEmpty
    }

    @objc private func pickToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { picked.insert(id) } else { picked.remove(id) }
        selectedCountLabel?.stringValue = "\(picked.count) selected"
        addSelectedButton?.title = picked.isEmpty ? "Add selected" : "Add \(picked.count) selected"
        addSelectedButton?.isEnabled = !picked.isEmpty
    }

    @objc private func closePickerPressed() {
        upstream = []
        picked = []
        filter = ""
        fetchError = nil
        rebuild()
    }

    @objc private func addSelectedPressed() {
        let existing = Set((entry?.models ?? []).map { $0.name.lowercased() })
        let fresh = upstream.filter { picked.contains($0.id) && !existing.contains($0.id.lowercased()) }
        guard !fresh.isEmpty else { return }
        onChange { provider in
            var next = provider
            next.models = provider.models + fresh.map { model in
                var def = ProviderModelDef(name: model.id)
                if let context = model.contextLength, context > 0 {
                    def.maxContextLength = context
                }
                return def
            }
            return PanelLogic.smartDefault(old: provider, next: next)
        }
        upstream.removeAll { fresh.contains($0) }
        picked = []
        rebuild()
    }

    @objc private func runFetchPressed() {
        guard let fetchUpstream else { return }
        fetching = true
        fetchError = nil
        rebuild()
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await fetchUpstream()
                self.upstream = list
                self.picked = []
                self.filter = ""
                self.fetchError = list.isEmpty ? "Upstream returned no models." : nil
            } catch {
                self.fetchError = (error as? PanelError)?.noticeText ?? error.localizedDescription
            }
            self.fetching = false
            self.rebuild()
        }
    }

    @objc private func addModelPressed() {
        onChange { provider in
            var next = provider
            next.models = provider.models + [ProviderModelDef(name: "")]
            return PanelLogic.smartDefault(old: provider, next: next)
        }
    }

    @objc private func smartAliasToggled(_ sender: NSSwitch) {
        let owner = aliasOwner().trimmingCharacters(in: .whitespaces)
        let on = sender.state == .on
        onChange { provider in
            var entry = provider
            if on {
                entry.models = provider.models.map { model in
                    var updated = model
                    updated.alias = PanelLogic.smartAliasFor(modelName: model.name, providerName: owner)
                    return updated
                }
            } else {
                entry.models = provider.models.map { model in
                    guard model.alias == PanelLogic.smartAliasFor(modelName: model.name, providerName: owner) else { return model }
                    var updated = model
                    updated.alias = nil
                    return updated
                }
            }
            return entry
        }
    }

    private func modelRow(modelIndex: Int, model: ProviderModelDef, smartAlias: Bool, owner: String) -> NSView {
        let smartForName = PanelLogic.smartAliasFor(modelName: model.name, providerName: owner)
        let aliasLocked = smartAlias && smartForName == model.alias

        let nameField = editableField(text: model.name, placeholder: "upstream-model-name",
                                      tag: "name:\(modelIndex)")
        let arrow = AppKitTheme.label("→", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

        let aliasField = editableField(text: aliasLocked ? smartForName : (model.alias ?? ""),
                                       placeholder: "alias (optional)", tag: "alias:\(modelIndex)")
        aliasField.isEnabled = !aliasLocked
        if aliasLocked { aliasField.toolTip = "Managed by Smart alias — toggle it off to edit" }

        let fetch = outlineButton(fetchingRow.contains(modelIndex) ? "…" : "Fetch")
        fetch.target = self
        fetch.action = #selector(fetchRowPressed(_:))
        fetch.identifier = NSUserInterfaceItemIdentifier("fetch:\(modelIndex)")
        fetch.isEnabled = !model.name.trimmingCharacters(in: .whitespaces).isEmpty && !fetchingRow.contains(modelIndex)
        fetch.toolTip = presetEfforts == nil
            ? "Fetch context window and effort levels for \(model.name.isEmpty ? "model" : model.name) from models.dev"
            : "Fetch context window for \(model.name.isEmpty ? "model" : model.name) from models.dev"
        let trash = iconButton("trash", color: .systemRed, action: #selector(removeRowPressed(_:)),
                               key: "remove:\(modelIndex)")

        let lineOne = NSStackView(views: [nameField, arrow, aliasField, SpacerView(), fetch, trash])
        lineOne.orientation = .horizontal
        lineOne.spacing = 8
        nameField.widthAnchor.constraint(equalTo: aliasField.widthAnchor, multiplier: 2).isActive = true

        let contextLabel = AppKitTheme.label("Context window:", font: .systemFont(ofSize: 11),
                                             color: .secondaryLabelColor)
        contextLabel.toolTip = "The window the client compacts against — never a cap on what raven forwards"
        let contextField = editableField(text: model.maxContextLength.map(String.init) ?? "",
                                         placeholder: "e.g. 200k", tag: "context:\(modelIndex)")
        contextField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let contextInfo = AppKitTheme.label(
            model.maxContextLength.map(PanelFormats.formatContextWindow)
                ?? "unset — the client keeps the launcher's default auto-compact window",
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        let lineTwo = NSStackView(views: [contextLabel, contextField, contextInfo])
        lineTwo.orientation = .horizontal
        lineTwo.spacing = 8

        let levels = model.thinking?.levels ?? []
        let lineThree: NSStackView
        if let presetEfforts {
            let effortLabel = AppKitTheme.label("Effort:", font: .systemFont(ofSize: 11),
                                                color: .secondaryLabelColor)
            var views: [NSView] = [effortLabel]
            let preset = presetEfforts(model.name)
            if preset.isEmpty {
                views.append(AppKitTheme.label("—", font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                               color: .secondaryLabelColor))
            } else {
                for level in preset {
                    let chip = AppKitTheme.label(level, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                                 color: .secondaryLabelColor)
                    chip.wantsLayer = true
                    chip.layer?.cornerRadius = 4
                    chip.layer?.borderWidth = 1
                    chip.layer?.borderColor = NSColor.separatorColor.cgColor
                    chip.toolTip = "Preconfigured — pick the effort per request in your client"
                    views.append(chip)
                }
            }
            views.append(AppKitTheme.label(preset.isEmpty ? "no reasoning control for this model"
                    : "· set per request by the client (reasoning_effort / thinking)",
                    font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
            lineThree = NSStackView(views: views)
        } else {
            let selected = Set(levels)
            let custom = levels.filter { !store.effortLevels.contains($0) }
            let effortLabel = AppKitTheme.label("Effort:", font: .systemFont(ofSize: 11),
                                                color: .secondaryLabelColor)
            var views: [NSView] = [effortLabel]
            for level in store.effortLevels {
                let chip = NSButton(title: level, target: self, action: #selector(effortToggled(_:)))
                chip.bezelStyle = .rounded
                chip.setButtonType(.pushOnPushOff)
                chip.controlSize = .small
                chip.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                chip.identifier = NSUserInterfaceItemIdentifier("level:\(modelIndex):\(level)")
                chip.state = selected.contains(level) ? .on : .off
                views.append(chip)
            }
            if !custom.isEmpty {
                let customField = editableField(text: custom.joined(separator: ","), placeholder: "custom…",
                                                tag: "custom:\(modelIndex)")
                customField.widthAnchor.constraint(equalToConstant: 110).isActive = true
                views.append(customField)
            }
            lineThree = NSStackView(views: views)
        }
        lineThree.orientation = .horizontal
        lineThree.spacing = 6

        var rows: [NSView] = [lineOne, lineTwo, lineThree]
        if let note = rowNotes[modelIndex] {
            let noteLabel = AppKitTheme.label(note, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            noteLabel.isSelectable = true
            rows.append(noteLabel)
        }

        let box = NSStackView(views: rows)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        for row in rows {
            row.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        }
        return box
    }

    private func editableField(text: String, placeholder: String, tag: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.controlSize = .small
        field.placeholderString = placeholder
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(tag)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    @objc private func removeRowPressed(_ sender: NSButton) {
        guard let modelIndex = parseKey(sender.identifier?.rawValue, prefix: "remove:") else { return }
        onChange { provider in
            var entry = provider
            entry.models = provider.models.enumerated().filter { $0.offset != modelIndex }.map(\.element)
            return entry
        }
    }

    @objc private func effortToggled(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, name.hasPrefix("level:") else { return }
        let pieces = name.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let modelIndex = Int(pieces[0]) else { return }
        let level = String(pieces[1])
        onChange { provider in
            var entry = provider
            guard modelIndex < entry.models.count else { return entry }
            var model = entry.models[modelIndex]
            let current = model.thinking?.levels ?? []
            let next = current.contains(level) ? current.filter { $0 != level } : current + [level]
            model = PanelLogic.withLevels(model, next: next)
            entry.models[modelIndex] = model
            return PanelLogic.smartDefault(old: provider, next: entry)
        }
    }

    @objc private func fetchRowPressed(_ sender: NSButton) {
        guard let modelIndex = parseKey(sender.identifier?.rawValue, prefix: "fetch:") else { return }
        guard let provider = entry, modelIndex < provider.models.count else { return }
        let name = provider.models[modelIndex].name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let wantsEfforts = presetEfforts == nil
        let knownLevels = store.effortLevels
        let customLevels = (provider.models[modelIndex].thinking?.levels ?? [])
            .filter { !knownLevels.contains($0) }
        rowNotes[modelIndex] = nil
        fetchingRow.insert(modelIndex)
        rebuild()
        Task { [weak self] in
            guard let self else { return }
            do {
                let lookup = try await self.store.fetchModelsDev(model: name)
                let fetchedContext = lookup.context
                let fetchedEfforts = wantsEfforts ? lookup.efforts : []
                if fetchedContext == nil && fetchedEfforts.isEmpty {
                    self.rowNotes[modelIndex] = "models.dev (\(lookup.source ?? "?")) lists no context window"
                        + (wantsEfforts ? " or effort levels" : "") + " for this model."
                } else {
                    self.onChange { provider in
                        var entry = provider
                        guard modelIndex < entry.models.count else { return entry }
                        var updated = entry.models[modelIndex]
                        if !fetchedEfforts.isEmpty {
                            updated = PanelLogic.withLevels(updated,
                                                            next: fetchedEfforts
                                                                + customLevels.filter { !fetchedEfforts.contains($0) })
                        }
                        if let fetchedContext {
                            updated = PanelLogic.withContext(updated, tokens: fetchedContext)
                        }
                        entry.models[modelIndex] = updated
                        return PanelLogic.smartDefault(old: provider, next: entry)
                    }
                    var got: [String] = []
                    if let fetchedContext { got.append("context \(PanelFormats.formatContextWindow(fetchedContext))") }
                    if !fetchedEfforts.isEmpty { got.append("effort levels") }
                    self.rowNotes[modelIndex] = "\(got.joined(separator: " + ")) from models.dev (\(lookup.source ?? "?"))"
                }
            } catch {
                let message = (error as? PanelError)?.noticeText ?? error.localizedDescription
                self.rowNotes[modelIndex] = PanelLogic.friendlyLookupError(message, what: "context window")
            }
            self.fetchingRow.remove(modelIndex)
            self.rebuild()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        activeField = notification.object as? NSTextField
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === activeField {
            activeField = nil
        }
        guard let name = field.identifier?.rawValue else { return }
        if name == "filter" {
            filter = field.stringValue
            if pendingRebuild {
                pendingRebuild = false
                rebuild()
            }
            return
        }
        let pieces = name.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, let modelIndex = Int(pieces[1]) else { return }
        commitField(modelIndex: modelIndex, role: String(pieces[0]), text: field.stringValue)
        if pendingRebuild {
            pendingRebuild = false
            rebuild()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.identifier?.rawValue == "filter" else { return }
        filter = field.stringValue
        updatePicker()
    }

    private func commitField(modelIndex: Int, role: String, text: String) {
        let knownLevels = store.effortLevels
        onChange { provider in
            var entry = provider
            guard modelIndex < entry.models.count else { return provider }
            var model = entry.models[modelIndex]
            switch role {
            case "name":
                model.name = text
            case "alias":
                model.alias = text.isEmpty ? nil : text
            case "context":
                model = PanelLogic.withContext(model, tokens: PanelLogic.parseTokenCount(text))
            case "custom":
                let selected = (model.thinking?.levels ?? []).filter { knownLevels.contains($0) }
                let custom = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                model = PanelLogic.withLevels(model, next: selected + custom)
            default:
                return provider
            }
            entry.models[modelIndex] = model
            return PanelLogic.smartDefault(old: provider, next: entry)
        }
    }

    private func parseKey(_ name: String?, prefix: String) -> Int? {
        guard let name, name.hasPrefix(prefix), let value = Int(name.dropFirst(prefix.count)) else { return nil }
        return value
    }
}

@MainActor
final class SpacerView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
}
