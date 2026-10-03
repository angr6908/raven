import AppKit

@MainActor
final class LaunchBarViewController: NSViewController {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let container = NSView()
    private let targetIcon = NSImageView()
    private let titleLabel = AppKitTheme.label("Select a model to launch",
                                               font: RavenType.mono(ofSize: 13), color: .secondaryLabelColor, lineLimit: 1)
    private let detailLabel = AppKitTheme.label("", font: RavenType.caption(), color: .secondaryLabelColor, lineLimit: 1)
    private let clientControl = NSSegmentedControl()
    private let workdirButton = NSButton()
    private let launchButton = AppKitTheme.glassButton(title: "Launch",
                                                       symbol: "play.fill",
                                                       prominent: true,
                                                       action: #selector(launchTapped),
                                                       target: AppKitTheme.self as AnyObject)
    private let overflowButton = NSButton()

    override func loadView() {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.effectIsInteractive = true
        glass.cornerRadius = 0
        glass.translatesAutoresizingMaskIntoConstraints = false
        view = glass

        container.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = container

        targetIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, kind) in ProviderKind.allCases.enumerated() {
            clientControl.setLabel(kind.displayName, forSegment: index)
            clientControl.setImage(AppKitTheme.symbol(kind.symbol, pointSize: 12, accessibilityLabel: kind.displayName),
                                   forSegment: index)
            clientControl.setWidth(0, forSegment: index)
        }
        clientControl.segmentCount = ProviderKind.allCases.count
        if #available(macOS 27.0, *) {
            clientControl.role = .valueSelection
        }
        clientControl.trackingMode = .selectOne
        clientControl.target = self
        clientControl.action = #selector(clientChanged(_:))
        clientControl.setContentHuggingPriority(.required, for: .horizontal)
        clientControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        clientControl.toolTip = "Which client to start"
        clientControl.setAccessibilityLabel("Client")

        workdirButton.bezelStyle = .glass
        workdirButton.controlSize = .large
        workdirButton.imagePosition = .imageLeading
        workdirButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Working folder")
        workdirButton.title = store.workdirLabel
        workdirButton.target = self
        workdirButton.action = #selector(workdirTapped(_:))
        workdirButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workdirButton.toolTip = "Launch in \(store.workdirPath) (⇧⌘O to change)"
        workdirButton.lineBreakMode = .byTruncatingMiddle
        workdirButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        workdirButton.setAccessibilityLabel("Working folder")

        launchButton.target = self
        launchButton.toolTip = "Open Terminal and start the selected model (⌘↩)"
        launchButton.setContentHuggingPriority(.required, for: .horizontal)
        launchButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        overflowButton.bezelStyle = .glass
        overflowButton.controlSize = .large
        overflowButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        overflowButton.imagePosition = .imageOnly
        overflowButton.title = ""
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped(_:))
        overflowButton.toolTip = "Launch script and configuration"
        overflowButton.setAccessibilityLabel("More launch options")

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [targetIcon, textStack, spacer, clientControl, workdirButton, launchButton, overflowButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let rowTop = row.topAnchor.constraint(equalTo: container.topAnchor, constant: RavenMetrics.spacing3)
        let rowBottom = row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -RavenMetrics.spacing3)
        rowTop.priority = .defaultHigh
        rowBottom.priority = .defaultHigh
        let textCap = textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        textCap.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rowTop,
            rowBottom,
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: RavenMetrics.spacing5),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -RavenMetrics.spacing5),
            targetIcon.widthAnchor.constraint(equalToConstant: 18),
            textCap,
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sync()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.selectedItem
            _ = self.store.client
            _ = self.store.workdir
            _ = self.workspace.isLaunching
            _ = self.workspace.didCopyScript
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
        if let item = store.selectedItem {
            titleLabel.stringValue = item.entry.modelID
            titleLabel.textColor = .labelColor
            titleLabel.toolTip = item.entry.modelID
            detailLabel.stringValue = "\(item.provider.name) · \(ContextWindow.label(store.effectiveWindow(item)))"
            detailLabel.isHidden = false
            targetIcon.image = NSImage(systemSymbolName: item.entry.family.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            targetIcon.contentTintColor = AppKitTheme.familyTint(item.entry.family)
            targetIcon.toolTip = "Launching \(item.entry.modelID) from \(item.provider.name)"
        } else {
            titleLabel.stringValue = "Select a model to launch"
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.isHidden = true
            targetIcon.image = nil
            targetIcon.toolTip = nil
        }
        clientControl.selectedSegment = ProviderKind.allCases.firstIndex(of: store.client) ?? 0
        workdirButton.title = store.workdirLabel
        workdirButton.toolTip = "Launch in \(store.workdirPath) (⇧⌘O to change)"
        launchButton.title = workspace.isLaunching ? "Launching…" : "Launch"
        launchButton.isEnabled = store.canLaunch && !workspace.isLaunching
    }

    @objc private func launchTapped() {
        workspace.launch()
    }

    @objc private func clientChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < ProviderKind.allCases.count else { return }
        store.client = ProviderKind.allCases[index]
    }

    @objc private func workdirTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let recents = store.recentWorkdirs.filter { $0 != store.workdir }
        if !recents.isEmpty {
            let header = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recents {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(selectWorkdir(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url.path
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let home = NSMenuItem(title: "Home", action: #selector(selectHome), keyEquivalent: "")
        home.target = self
        home.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        menu.addItem(home)
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseWorkdir), keyEquivalent: "")
        choose.target = self
        choose.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(choose)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealWorkdir), keyEquivalent: "")
        reveal.target = self
        reveal.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(reveal)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectWorkdir(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        store.workdir = URL(fileURLWithPath: path, isDirectory: true)
        store.rememberWorkdir()
    }

    @objc private func selectHome() {
        store.workdir = .homeDirectory
        store.rememberWorkdir()
    }

    @objc private func chooseWorkdir() {
        workspace.chooseWorkdir()
    }

    @objc private func revealWorkdir() {
        workspace.revealWorkdir()
    }

    @objc private func overflowTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let copy = NSMenuItem(title: workspace.didCopyScript ? "Copied" : "Copy Launch Script",
                              action: #selector(copyScript), keyEquivalent: "")
        copy.target = self
        copy.image = AppKitTheme.symbol(workspace.didCopyScript ? "checkmark" : "document.on.document", pointSize: 12)
        copy.isEnabled = store.canLaunch
        menu.addItem(copy)
        let show = NSMenuItem(title: "Show Launch Script…", action: #selector(showScript), keyEquivalent: "")
        show.target = self
        show.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
        show.isEnabled = store.canLaunch
        menu.addItem(show)
        menu.addItem(.separator())
        let config = NSMenuItem(title: "Show Configuration in Finder", action: #selector(revealConfig), keyEquivalent: "")
        config.target = self
        config.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(config)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyScript() {
        workspace.copyScript()
    }

    @objc private func showScript() {
        workspace.isShowingScript = true
    }

    @objc private func revealConfig() {
        workspace.revealConfig()
    }
}
