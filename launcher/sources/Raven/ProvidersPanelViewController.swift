import AppKit

@MainActor
final class DisclosureCardView: NSView {
    let headerRow = NSStackView()
    let bodyStack = NSStackView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let trailingLabel: NSTextField
    private let badgesRow = NSStackView()
    private let chevron = NSImageView()
    private let toggleZone = NSStackView()
    private let accessoryRow = NSStackView()
    private let card: GlassCardView
    private(set) var isExpanded = false
    var onToggle: (() -> Void)?

    init(title: String, monospacedTitle: Bool) {
        titleLabel = AppKitTheme.label(title,
                                       font: monospacedTitle ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 13, weight: .medium),
                                       color: .labelColor, lineLimit: 1)
        subtitleLabel = AppKitTheme.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lineLimit: 1)
        trailingLabel = AppKitTheme.label("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        card = AppKitTheme.glassCard(interactive: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, badgesRow])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgesRow.orientation = .horizontal
        badgesRow.spacing = 6
        let textColumn = NSStackView(views: [titleRow, subtitleLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2

        toggleZone.orientation = .horizontal
        toggleZone.spacing = 8
        toggleZone.addArrangedSubview(chevron)
        toggleZone.addArrangedSubview(textColumn)

        accessoryRow.orientation = .horizontal
        accessoryRow.spacing = 8

        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.addArrangedSubview(toggleZone)
        headerRow.addArrangedSubview(trailingLabel)
        headerRow.addArrangedSubview(accessoryRow)
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
        textColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 12
        bodyStack.isHidden = true

        let shell = NSStackView(views: [headerRow, bodyStack])
        shell.orientation = .vertical
        shell.alignment = .leading
        shell.spacing = 10
        shell.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        shell.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(shell)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            shell.topAnchor.constraint(equalTo: card.content.topAnchor),
            shell.leadingAnchor.constraint(equalTo: card.content.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: card.content.trailingAnchor),
            shell.bottomAnchor.constraint(equalTo: card.content.bottomAnchor),
            headerRow.widthAnchor.constraint(equalTo: shell.widthAnchor, constant: -24),
            bodyStack.widthAnchor.constraint(equalTo: shell.widthAnchor, constant: -24),
            chevron.widthAnchor.constraint(equalToConstant: 14),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        toggleZone.addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title.isEmpty ? "unnamed" : title
    }

    func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
    }

    func setTrailing(_ text: String) {
        trailingLabel.stringValue = text
    }

    func setBadges(_ labels: [String]) {
        badgesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for text in labels {
            badgesRow.addArrangedSubview(AppKitTheme.pill(text, color: .secondaryLabelColor))
        }
    }

    func addHeaderAccessory(_ views: [NSView]) {
        accessoryRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            accessoryRow.addArrangedSubview(view)
        }
    }

    func setBody(_ views: [NSView]) {
        let mounted = bodyStack.arrangedSubviews.map { ObjectIdentifier($0) }
        let next = views.map { ObjectIdentifier($0) }
        guard mounted != next else { return }
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            bodyStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
    }

    func setDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.animator().alphaValue = dimmed ? 0.55 : 1
        })
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        bodyStack.isHidden = !expanded
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        chevron.contentTintColor = .secondaryLabelColor
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.chevron.animator().alphaValue = 0.01
        }, completionHandler: {
            self.chevron.alphaValue = 1
        })
    }

    @objc private func headerClicked() {
        setExpanded(!isExpanded)
        onToggle?()
    }
}

@MainActor
final class ProvidersPanelViewController: NSViewController, NSTextFieldDelegate {
    private let store = ProvidersPanelStore.shared
    private var autoExpandedCards: Set<String> = []
    private let tracker = ObservationTracker()
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    private let notice = PanelNoticeView()
    private let saveDot = NSView()
    private let saveLabel = AppKitTheme.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let managedStack = NSStackView()
    private let providerStack = NSStackView()
    private let emptyProvidersLabel = AppKitTheme.label(
        "No API key providers configured. Add one to route models through an OpenAI-compatible or Responses endpoint.",
        font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

    private var zoneCards: [ZoneCardControls] = []
    private var providerCards: [ProviderCardControls] = []
    private var firstProviderIndex: Int?
    private weak var activeField: NSTextField?
    private var pendingRender = false
    private var loadingView: CenteredLoaderView?

    override func loadView() {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view = NSView()
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 24, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        addFull(notice)

        saveDot.wantsLayer = true
        saveDot.layer?.cornerRadius = 3
        saveDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        saveDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        saveLabel.setContentHuggingPriority(.required, for: .horizontal)
        let saveRow = NSStackView(views: [SpacerView(), saveDot, saveLabel])
        saveRow.orientation = .horizontal
        saveRow.spacing = 6
        saveRow.alignment = .centerY
        saveRow.isHidden = true
        saveRow.identifier = NSUserInterfaceItemIdentifier("save-row")
        addFull(saveRow)
        self.saveRow = saveRow

        addFull(AppKitTheme.label("Managed channels", font: .systemFont(ofSize: 13, weight: .medium),
                                  color: .labelColor))
        configureColumn(managedStack)
        addFull(managedStack)

        let addProvider = smallButton("Add provider", symbol: "plus", action: #selector(addProviderPressed))
        let providersHeader = NSStackView(views: [
            AppKitTheme.label("API key providers", font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor),
            SpacerView(),
            addProvider,
        ])
        providersHeader.orientation = .horizontal
        providersHeader.spacing = 10
        addFull(providersHeader)

        configureColumn(providerStack)
        addFull(providerStack)

        emptyProvidersLabel.maximumNumberOfLines = 0
        emptyProvidersLabel.lineBreakMode = .byWordWrapping
        emptyProvidersLabel.isHidden = true
        addFull(emptyProvidersLabel)
    }

    private var saveRow: NSStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.providers
            _ = self.store.loading
            _ = self.store.error
            _ = self.store.effortLevels
            _ = self.store.saver.status
            self.scheduleRender()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        store.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func configureColumn(_ column: NSStackView) {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
    }

    private func addFull(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(subview)
        subview.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        subview.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
    }

    private func smallButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let image = AppKitTheme.symbol(symbol, pointSize: 10) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func scheduleRender() {
        guard activeField == nil else {
            pendingRender = true
            return
        }
        render()
    }

    @objc private func addProviderPressed() {
        store.addProvider()
        firstProviderIndex = 0
    }

    private func render() {
        renderSaveStatus()
        notice.show(store.error)

        guard !store.loading, store.providers != nil else {
            if loadingView == nil {
                let loader = CenteredLoaderView(message: "Loading providers…")
                loader.heightAnchor.constraint(equalToConstant: 160).isActive = true
                addFull(loader)
                loadingView = loader
            }
            return
        }
        loadingView?.removeFromSuperview()
        loadingView = nil

        let list = store.providers ?? []
        renderManagedZones(list)

        let endpoints = list.enumerated().filter { !$0.element.isManaged }.map { (index: $0.offset, entry: $0.element) }
        firstProviderIndex = endpoints.first?.index
        emptyProvidersLabel.isHidden = !endpoints.isEmpty
        while providerCards.count < endpoints.count {
            let slot = providerCards.count
            let controls = makeProviderControls(slot: slot)
            providerCards.append(controls)
            providerStack.addArrangedSubview(controls.card)
            controls.card.widthAnchor.constraint(equalTo: providerStack.widthAnchor).isActive = true
        }
        while providerCards.count > endpoints.count {
            providerCards.removeLast().card.removeFromSuperview()
        }
        for (slot, item) in endpoints.enumerated() {
            renderProviderCard(slot: slot, item: item)
        }
    }

    private func renderSaveStatus() {
        switch store.saver.status {
        case .idle:
            saveRow.isHidden = true
        case .saving:
            saveRow.isHidden = false
            saveDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            saveLabel.stringValue = "Saving…"
            saveLabel.textColor = .secondaryLabelColor
        case .saved:
            saveRow.isHidden = false
            saveDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            saveLabel.stringValue = ProvidersPanelStore.savedNotice
            saveLabel.textColor = .secondaryLabelColor
        case .failed(let message):
            saveRow.isHidden = false
            saveDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            saveLabel.stringValue = "Save failed — \(message)"
            saveLabel.textColor = .systemRed
        }
    }


    private struct ZoneSpec {
        let title: String
        let match: (ProviderEntry) -> Bool
        let blank: () -> ProviderEntry
        let aliasOwner: String
        let followEntryName: Bool
        let fetchKind: String
        let presets: Bool
        let emptyHint: String
    }

    private static let zoneSpecs: [ZoneSpec] = [
        ZoneSpec(title: "Command Code", match: { $0.kind == "commandcode" },
                 blank: { PanelLogic.blankProviderEntry(kind: "commandcode", name: "CommandCode") },
                 aliasOwner: "CommandCode", followEntryName: true, fetchKind: "commandcode", presets: false,
                 emptyHint: "No models pinned — fetch the catalog and pick, or add a row by hand."),
        ZoneSpec(title: "WorkBuddy", match: { $0.kind == "workbuddy" },
                 blank: { PanelLogic.blankProviderEntry(kind: "workbuddy", name: "workbuddy") },
                 aliasOwner: "workbuddy", followEntryName: false, fetchKind: "workbuddy", presets: false,
                 emptyHint: "No models pinned — fetch the upstream catalog and pick, or add a row by hand. Unlisted workbuddy ids still route by name."),
        ZoneSpec(title: "Antigravity", match: { $0.kind == "antigravity" },
                 blank: { PanelLogic.blankProviderEntry(kind: "antigravity", name: "antigravity") },
                 aliasOwner: "antigravity", followEntryName: false, fetchKind: "antigravity", presets: true,
                 emptyHint: "No models pinned — fetch the catalog and pick, or add a row by hand. Unlisted antigravity ids still route by name."),
    ]

    private struct ZoneCardControls {
        let card: DisclosureCardView
        let zone: ModelZoneView
        let toggle: NSSwitch
    }

    private func renderManagedZones(_ list: [ProviderEntry]) {
        while zoneCards.count < Self.zoneSpecs.count {
            let index = zoneCards.count
            let spec = Self.zoneSpecs[index]
            let card = DisclosureCardView(title: spec.title, monospacedTitle: false)
            let zone = ModelZoneView()
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(zoneEnabledToggled(_:))
            card.addHeaderAccessory([
                AppKitTheme.label("Enabled", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
                toggle,
            ])
            card.onToggle = { [weak self] in self?.scheduleRender() }
            zoneCards.append(ZoneCardControls(card: card, zone: zone, toggle: toggle))
            managedStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: managedStack.widthAnchor).isActive = true
            wireZone(zone: zone, slot: index)
        }

        for (index, spec) in Self.zoneSpecs.enumerated() {
            let controls = zoneCards[index]
            let entry = list.first(where: spec.match)
            let enabled = !(entry?.disabled ?? false)
            let models = entry?.models ?? []
            controls.card.setSubtitle(models.isEmpty ? "no models pinned — pass-through"
                : "\(models.count) model\(models.count == 1 ? "" : "s") pinned")
            controls.card.setTrailing(models.isEmpty ? "pass-through" : "\(models.count) pinned")
            controls.card.setBadges(enabled ? [] : ["off"])
            controls.card.setDimmed(!enabled)
            controls.zone.entryProvider = { [weak self] in self?.store.providers?.first(where: spec.match) }
            controls.zone.aliasOwner = { [weak self] in
                guard spec.followEntryName,
                      let name = self?.store.providers?.first(where: spec.match)?.name
                        .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return spec.aliasOwner }
                return name
            }
            controls.zone.onChange = { [weak self] change in
                self?.store.editZone(match: spec.match, blank: spec.blank, change: change)
            }
            if controls.card.isExpanded {
                controls.card.setBody([controls.zone])
                controls.zone.rebuild()
            }
            controls.toggle.state = enabled ? .on : .off
        }
    }

    private func wireZone(zone: ModelZoneView, slot: Int) {
        let spec = Self.zoneSpecs[slot]
        zone.emptyHint = spec.emptyHint
        zone.fetchUpstream = {
            let fetched = try await ProvidersPanelStore.shared.fetchZoneModels(kind: spec.fetchKind)
            if spec.presets {
                ProvidersPanelStore.shared.updateAntigravityLevels(from: fetched)
            }
            return fetched
        }
        zone.presetEfforts = spec.presets ? { name in
            ProvidersPanelStore.shared.antigravityLevels[name] ?? []
        } : nil
    }

    @objc private func zoneEnabledToggled(_ sender: NSSwitch) {
        guard let index = zoneCards.firstIndex(where: { $0.toggle === sender }) else { return }
        let spec = Self.zoneSpecs[index]
        store.editZone(match: spec.match, blank: spec.blank) { entry in
            var updated = entry
            updated.disabled = sender.state != .on
            return updated
        }
    }


    private struct ProviderCardControls {
        let card: DisclosureCardView
        let zone: ModelZoneView
        let toggle: NSSwitch
        let removeButton: NSButton
    }

    private func makeProviderControls(slot: Int) -> ProviderCardControls {
        let card = DisclosureCardView(title: "", monospacedTitle: true)
        let zone = ModelZoneView()
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.tag = slot
        toggle.target = self
        toggle.action = #selector(providerEnabledToggled(_:))
        let removeButton = NSButton(image: AppKitTheme.symbol("trash", color: .systemRed, pointSize: 11) ?? NSImage(),
                                    target: self, action: #selector(removeProviderPressed(_:)))
        removeButton.isBordered = false
        removeButton.controlSize = .small
        removeButton.tag = slot
        card.addHeaderAccessory([
            AppKitTheme.label("Enabled", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
            toggle,
            removeButton,
        ])
        card.onToggle = { [weak self] in self?.scheduleRender() }
        zone.emptyHint = "No models — every upstream model is passed through."
        zone.entryProvider = { [weak self] in
            guard let self, let index = self.providerSlotIndex(slot) else { return nil }
            return index < self.store.providers?.count ?? -1 ? self.store.providers?[index] : nil
        }
        zone.aliasOwner = { [weak self] in
            guard let self, let index = self.providerSlotIndex(slot),
                  index < self.store.providers?.count ?? -1 else { return "" }
            return self.store.providers?[index].name ?? ""
        }
        zone.fetchUpstream = { [weak self] in
            guard let index = self?.providerSlotIndex(slot) else { return [] }
            return try await ProvidersPanelStore.shared.fetchProviderModels(index: index)
        }
        zone.presetEfforts = nil
        zone.onChange = { [weak self] change in
            guard let self, let index = self.providerSlotIndex(slot) else { return }
            self.store.updateProvider(index: index, change)
        }
        return ProviderCardControls(card: card, zone: zone, toggle: toggle, removeButton: removeButton)
    }

    private func providerSlotIndex(_ slot: Int) -> Int? {
        let endpoints = (store.providers ?? []).enumerated().filter { !$0.element.isManaged }.map(\.offset)
        return slot < endpoints.count ? endpoints[slot] : nil
    }

    private func renderProviderCard(slot: Int, item: (index: Int, entry: ProviderEntry)) {
        let controls = providerCards[slot]
        let provider = item.entry
        let kind = provider.kind ?? "openai"
        let models = provider.models
        let keys = provider.apiKeyEntries
        controls.card.setTitle(provider.name)
        controls.card.setSubtitle(provider.baseUrl?.isEmpty == false ? provider.baseUrl! : "no base url")
        var summary = models.isEmpty ? "pass-through" : "\(models.count) model\(models.count == 1 ? "" : "s")"
        if !keys.isEmpty {
            summary += " · \(keys.count) key\(keys.count == 1 ? "" : "s")"
        }
        controls.card.setTrailing(summary)
        var badges = [kindBadge(kind)]
        if provider.disabled == true { badges.append("off") }
        controls.card.setBadges(badges)
        controls.card.setDimmed(provider.disabled == true)

        let identity = "\(item.index):\(provider.name)"
        if item.index == firstProviderIndex && provider.name.isEmpty,
           !controls.card.isExpanded, !autoExpandedCards.contains(identity) {
            autoExpandedCards.insert(identity)
            controls.card.setExpanded(true)
        }
        controls.toggle.state = provider.disabled == true ? .off : .on

        guard controls.card.isExpanded else {
            controls.card.setBody([])
            return
        }
        controls.card.setBody([editorGrid(slot: slot, provider: provider), keysSection(slot: slot),
                               ] + keyRows(slot: slot, keys: keys) + [controls.zone])
        controls.zone.rebuild()
    }

    private func kindBadge(_ kind: String) -> String {
        kind == "responses" ? "responses" : "openai"
    }

    private func editorGrid(slot: Int, provider: ProviderEntry) -> NSView {
        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.distribution = .fillEqually
        grid.spacing = 12
        grid.addArrangedSubview(fieldColumn(label: "Name", text: provider.name,
                                            placeholder: "e.g. openrouter", tag: "pname:\(slot)"))
        grid.addArrangedSubview(fieldColumn(label: "Base URL", text: provider.baseUrl ?? "",
                                            placeholder: "https://api.example.com/v1", tag: "purl:\(slot)"))
        grid.addArrangedSubview(kindColumn(slot: slot, kind: provider.kind ?? "openai"))
        return grid
    }

    private func fieldColumn(label: String, text: String, placeholder: String, tag: String) -> NSView {
        let titleLabel = AppKitTheme.label(label, font: .systemFont(ofSize: 11, weight: .medium),
                                           color: .secondaryLabelColor)
        let field = NSTextField(string: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .small
        field.placeholderString = placeholder
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(tag)
        let column = NSStackView(views: [titleLabel, field])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func kindColumn(slot: Int, kind: String) -> NSView {
        let titleLabel = AppKitTheme.label("Kind", font: .systemFont(ofSize: 11, weight: .medium),
                                           color: .secondaryLabelColor)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        popup.addItems(withTitles: ["OpenAI-compatible endpoint", "OpenAI Responses endpoint"])
        popup.selectItem(at: kind == "responses" ? 1 : 0)
        popup.target = self
        popup.action = #selector(kindChanged(_:))
        popup.tag = slot
        let column = NSStackView(views: [titleLabel, popup])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        popup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func keyRows(slot: Int, keys: [ApiKeyEntry]) -> [NSView] {
        guard !keys.isEmpty else {
            return [AppKitTheme.label("None.", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)]
        }
        return keys.enumerated().map { keyIndex, keyEntry in
            let field = NSTextField(string: keyEntry.apiKey)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.controlSize = .small
            field.placeholderString = "sk-…"
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier("pkey:\(slot):\(keyIndex)")
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let remove = NSButton(image: AppKitTheme.symbol("trash", color: .systemRed, pointSize: 11) ?? NSImage(),
                                  target: self, action: #selector(removeKeyPressed(_:)))
            remove.isBordered = false
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier("rmkey:\(slot):\(keyIndex)")
            let row = NSStackView(views: [field, remove])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
    }

    private func keysSection(slot: Int) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.addArrangedSubview(AppKitTheme.label("API keys", font: .systemFont(ofSize: 11, weight: .medium),
                                                    color: .secondaryLabelColor))
        header.addArrangedSubview(SpacerView())
        let addKey = NSButton(title: "Add key", target: self, action: #selector(addKeyPressed(_:)))
        addKey.bezelStyle = .rounded
        addKey.controlSize = .small
        addKey.font = .systemFont(ofSize: 11)
        addKey.tag = slot
        if let image = AppKitTheme.symbol("plus", pointSize: 10) {
            addKey.image = image
            addKey.imagePosition = .imageLeading
        }
        header.addArrangedSubview(addKey)
        return header
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard let index = providerSlotIndex(sender.tag) else { return }
        let kind = sender.indexOfSelectedItem == 1 ? "responses" : "openai"
        store.updateProvider(index: index) { entry in
            var updated = entry
            updated.kind = kind
            return PanelLogic.smartDefault(old: entry, next: updated)
        }
    }

    @objc private func providerEnabledToggled(_ sender: NSSwitch) {
        guard let index = providerSlotIndex(sender.tag) else { return }
        store.updateProvider(index: index) { entry in
            var updated = entry
            updated.disabled = sender.state != .on
            return updated
        }
    }

    @objc private func removeProviderPressed(_ sender: NSButton) {
        guard let index = providerSlotIndex(sender.tag), let window = view.window else { return }
        let alert = NSAlert()
        let name = store.providers?[index].name ?? "unnamed"
        alert.messageText = "Remove provider “\(name)”?"
        alert.informativeText = "Its models and API keys are dropped from the routing doc on save."
        alert.addButton(withTitle: "Remove \(name)")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.store.removeProvider(index: index)
            }
        }
    }

    @objc private func addKeyPressed(_ sender: NSButton) {
        guard let index = providerSlotIndex(sender.tag) else { return }
        store.updateProvider(index: index) { entry in
            var updated = entry
            updated.apiKeyEntries = entry.apiKeyEntries + [ApiKeyEntry(apiKey: "")]
            return updated
        }
    }

    @objc private func removeKeyPressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let pieces = name.split(separator: ":")
        guard pieces.count == 3, let slot = Int(pieces[1]), let keyIndex = Int(pieces[2]),
              let index = providerSlotIndex(slot) else { return }
        store.updateProvider(index: index) { entry in
            var updated = entry
            updated.apiKeyEntries = entry.apiKeyEntries.enumerated().filter { $0.offset != keyIndex }.map(\.element)
            return updated
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        activeField = notification.object as? NSTextField
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === activeField {
            activeField = nil
        }
        guard let field = notification.object as? NSTextField, let name = field.identifier?.rawValue else { return }
        let pieces = name.split(separator: ":")
        guard pieces.count >= 2, let slot = Int(pieces[1]), let index = providerSlotIndex(slot) else { return }
        switch pieces[0] {
        case "pname":
            store.updateProvider(index: index) { entry in
                var updated = entry
                updated.name = field.stringValue
                return PanelLogic.smartDefault(old: entry, next: updated)
            }
        case "purl":
            store.updateProvider(index: index) { entry in
                var updated = entry
                updated.baseUrl = field.stringValue
                return PanelLogic.smartDefault(old: entry, next: updated)
            }
        case "pkey":
            guard pieces.count == 3, let keyIndex = Int(pieces[2]) else { return }
            store.updateProvider(index: index) { entry in
                var updated = entry
                guard keyIndex < updated.apiKeyEntries.count else { return entry }
                updated.apiKeyEntries[keyIndex].apiKey = field.stringValue
                return updated
            }
        default:
            return
        }
        if pendingRender {
            pendingRender = false
            render()
        }
    }
}
