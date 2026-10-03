import AppKit

@MainActor
final class ProviderSheetViewController: NSViewController, NSTextFieldDelegate {
    private let draft: ProviderDraft
    private let workspace: Workspace
    private let onFinish: (Bool) -> Void
    private let tracker = ObservationTracker()

    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let revealButton = NSButton()
    private let footerLabel = AppKitTheme.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let resultStack = NSView()
    private var resultContent: NSView?
    private var testButton: NSButton!
    private let validationLabel = AppKitTheme.label("", font: .systemFont(ofSize: 12), color: .systemRed)
    private let confirmButton = NSButton()

    init(draft: ProviderDraft, workspace: Workspace, onFinish: @escaping (Bool) -> Void) {
        self.draft = draft
        self.workspace = workspace
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        nameField.placeholderString = "My provider"
        nameField.stringValue = draft.name
        nameField.delegate = self
        urlField.placeholderString = LocalProxy.baseURL
        urlField.stringValue = draft.baseURL
        urlField.delegate = self
        urlField.cell?.usesSingleLineMode = true
        keyField.placeholderString = "Optional"
        keyField.stringValue = draft.apiKey
        keyField.delegate = self

        revealButton.setButtonType(.pushOnPushOff)
        revealButton.bezelStyle = .texturedRounded
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Reveal")
        revealButton.imagePosition = .imageOnly
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)

        let keyRow = NSStackView(views: [keyField, revealButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6

        testButton = AppKitTheme.glassButton(title: "Test", symbol: nil, prominent: false,
                                             action: #selector(testTapped), target: self)
        testButton.controlSize = .small

        resultStack.translatesAutoresizingMaskIntoConstraints = false
        resultStack.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let connectionRow = NSStackView(views: [resultStack, testButton])
        connectionRow.orientation = .horizontal
        connectionRow.spacing = 8

        validationLabel.isHidden = true
        footerLabel.stringValue = "Raven reads models from \(draft.fetchPreview)"

        confirmButton.title = draft.isEditing ? "Save" : "Add"
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let fieldStack = NSStackView(views: [nameField, urlField, keyRow])
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.distribution = .fill
        fieldStack.spacing = 10
        for field in [nameField, urlField] as [NSView] {
            field.widthAnchor.constraint(equalTo: fieldStack.widthAnchor).isActive = true
        }
        keyRow.widthAnchor.constraint(equalTo: fieldStack.widthAnchor).isActive = true
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let body = NSStackView(views: [
            sectionLabel("Name", top: false),
            fieldStack,
            sectionLabel("Connection", top: true),
            connectionRow,
            validationLabel,
            footerLabel,
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 20),
        ])
        view = root
    }

    private func sectionLabel(_ text: String, top: Bool) -> NSView {
        let label = AppKitTheme.label(text, font: .systemFont(ofSize: 11, weight: .semibold),
                                      color: .secondaryLabelColor)
        guard top else { return label }
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        ])
        return container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sync()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.draft.testState
            _ = self.draft.validationMessage
            _ = self.draft.revealKey
            _ = self.draft.baseURL
            _ = self.draft.canTest
            self.sync()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        view.window?.makeFirstResponder(nameField)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func sync() {
        footerLabel.stringValue = "Raven reads models from \(draft.fetchPreview)"
        testButton.isEnabled = draft.canTest

        resultContent?.removeFromSuperview()
        let label: NSTextField
        switch draft.testState {
        case .idle:
            label = AppKitTheme.label("Not tested", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .testing:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            resultStack.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.leadingAnchor.constraint(equalTo: resultStack.leadingAnchor),
                spinner.centerYAnchor.constraint(equalTo: resultStack.centerYAnchor),
            ])
            resultContent = spinner
            testButton.isHidden = true
            return
        case .success(let count):
            label = AppKitTheme.label(count == 1 ? "1 model" : "\(count) models",
                                      font: .systemFont(ofSize: 12), color: .systemGreen)
        case .failure(let message):
            label = AppKitTheme.label(message, font: .systemFont(ofSize: 12), color: .systemRed, lineLimit: 1)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = message
        }
        testButton.isHidden = false
        label.identifier = NSUserInterfaceItemIdentifier("result")
        resultStack.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: resultStack.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: resultStack.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: resultStack.centerYAnchor),
        ])
        resultContent = label

        if let message = draft.validationMessage {
            validationLabel.stringValue = message
            validationLabel.isHidden = false
        } else {
            validationLabel.isHidden = true
        }

        syncKeyField()
    }

    private var revealedKeyField: NSTextField?
    private var keyRow: NSStackView?

    private func syncKeyField() {
        guard let row = keyRow ?? keyField.superview as? NSStackView else { return }
        keyRow = row
        if draft.revealKey {
            guard revealedKeyField == nil else { return }
            let plain = NSTextField()
            plain.placeholderString = "Optional"
            plain.stringValue = draft.apiKey
            plain.delegate = self
            plain.target = self
            plain.action = #selector(keyPlainChanged(_:))
            plain.translatesAutoresizingMaskIntoConstraints = false
            keyField.isHidden = true
            row.insertArrangedSubview(plain, at: 0)
            plain.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            revealedKeyField = plain
        } else {
            guard let plain = revealedKeyField else {
                keyField.isHidden = false
                return
            }
            revealedKeyField = nil
            plain.removeFromSuperview()
            keyField.isHidden = false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field {
        case nameField: draft.name = field.stringValue
        case urlField: draft.baseURL = field.stringValue
        case keyField: draft.apiKey = field.stringValue
        default: break
        }
    }

    @objc private func keyPlainChanged(_ sender: NSTextField) {
        draft.apiKey = sender.stringValue
    }

    @objc private func toggleReveal() {
        draft.revealKey.toggle()
    }

    @objc private func testTapped() {
        draft.testConnection()
    }

    @objc private func confirmTapped() {
        guard draft.validated() != nil else {
            sync()
            return
        }
        onFinish(true)
        view.window?.close()
    }

    @objc private func cancelTapped() {
        onFinish(false)
        view.window?.close()
    }
}

@MainActor
final class ContextWindowSheetViewController: NSViewController, NSTextFieldDelegate {
    private let draft: WindowDraft
    private let workspace: Workspace
    private let onFinish: (Bool) -> Void
    private let tracker = ObservationTracker()

    private let useAdvertisedToggle = NSButton(checkboxWithTitle: "Use the window the provider reports",
                                               target: nil, action: nil)
    private let tokensField = NSTextField()
    private let presetControl = NSSegmentedControl()
    private let effectiveLabel = AppKitTheme.label("Enter a positive number",
                                                   font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .systemRed)
    private let modelLabel = AppKitTheme.label("", font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                               color: .labelColor, lineLimit: 1)
    private let confirmButton = NSButton()

    init(draft: WindowDraft, workspace: Workspace, onFinish: @escaping (Bool) -> Void) {
        self.draft = draft
        self.workspace = workspace
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        modelLabel.stringValue = draft.modelID
        modelLabel.lineBreakMode = .byTruncatingMiddle

        useAdvertisedToggle.target = self
        useAdvertisedToggle.action = #selector(toggleAdvertised(_:))
        useAdvertisedToggle.state = draft.useAdvertised ? .on : .off
        useAdvertisedToggle.isHidden = draft.advertised == nil

        tokensField.stringValue = draft.text
        tokensField.placeholderString = "200000"
        tokensField.delegate = self

        let presets = ContextWindow.presets
        presetControl.segmentCount = presets.count + 1
        for (index, preset) in presets.enumerated() {
            presetControl.setLabel(ContextWindow.compact(preset), forSegment: index)
            presetControl.setWidth(0, forSegment: index)
        }
        presetControl.setLabel("Custom", forSegment: presets.count)
        presetControl.trackingMode = .selectOne
        presetControl.target = self
        presetControl.action = #selector(presetChanged(_:))

        let footer = AppKitTheme.label(
            "Sets where the client's context bar fills and auto-compaction fires. Nothing is capped upstream.",
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        footer.maximumNumberOfLines = 0
        footer.lineBreakMode = .byWordWrapping

        confirmButton.title = "Save"
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let effectiveRow = NSStackView(views: [
            AppKitTheme.label("Effective", font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor),
            effectiveLabel,
        ])
        effectiveRow.orientation = .horizontal
        effectiveRow.spacing = 8

        let body = NSStackView(views: [modelLabel, useAdvertisedToggle, tokensField, presetControl, effectiveRow, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        tokensField.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 20),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sync()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.draft.useAdvertised
            _ = self.draft.text
            self.sync()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        if !draft.useAdvertised {
            view.window?.makeFirstResponder(tokensField)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func sync() {
        useAdvertisedToggle.isHidden = draft.advertised == nil
        tokensField.isHidden = draft.useAdvertised
        presetControl.isHidden = draft.useAdvertised
        let index = ContextWindow.presets.firstIndex { $0 == draft.tokens }
        presetControl.selectedSegment = index ?? ContextWindow.presets.count
        if let preview = draft.preview {
            effectiveLabel.stringValue = preview
            effectiveLabel.textColor = .secondaryLabelColor
        } else {
            effectiveLabel.stringValue = "Enter a positive number"
            effectiveLabel.textColor = .systemRed
        }
        confirmButton.isEnabled = draft.isValid
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === tokensField else { return }
        draft.text = field.stringValue
    }

    @objc private func toggleAdvertised(_ sender: NSButton) {
        draft.useAdvertised = sender.state == .on
    }

    @objc private func presetChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < ContextWindow.presets.count else { return }
        draft.text = String(ContextWindow.presets[index])
    }

    @objc private func confirmTapped() {
        onFinish(true)
        view.window?.close()
    }

    @objc private func cancelTapped() {
        onFinish(false)
        view.window?.close()
    }
}

@MainActor
final class ScriptSheetViewController: NSViewController {
    private let store: ProviderStore
    private let workspace: Workspace
    private let onClose: () -> Void
    private let tracker = ObservationTracker()

    private let textView = NSTextView()
    private let copyButton = AppKitTheme.glassButton(title: "Copy",
                                                     symbol: "document.on.document",
                                                     prominent: false,
                                                     action: #selector(copyTapped),
                                                     target: AppKitTheme.self as AnyObject)

    init(store: ProviderStore, workspace: Workspace, onClose: @escaping () -> Void) {
        self.store = store
        self.workspace = workspace
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.string = store.launchScript() ?? ""
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        scroll.documentView = textView
        root.addSubview(scroll)

        copyButton.target = self

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [copyButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.workspace.didCopyScript
            self.syncCopyButton()
        }
        syncCopyButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func syncCopyButton() {
        copyButton.title = workspace.didCopyScript ? "Copied" : "Copy"
        copyButton.image = AppKitTheme.symbol(workspace.didCopyScript ? "checkmark" : "document.on.document", pointSize: 12)
    }

    @objc private func copyTapped() {
        workspace.copyScript()
    }

    @objc private func doneTapped() {
        onClose()
        view.window?.close()
    }
}
