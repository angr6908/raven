import AppKit

@MainActor
final class DetailContainerViewController: NSViewController {
    private let store = RavenRuntime.shared.store
    private let workspace = RavenRuntime.shared.workspace
    private let tracker = ObservationTracker()

    private let background = NSVisualEffectView()
    private let host = NSView()
    private let launchBar = LaunchBarViewController()

    private var hostBottomToBackground: NSLayoutConstraint!
    private var hostBottomToBar: NSLayoutConstraint!

    private var current: NSViewController?
    private var panelControllers: [Destination: NSViewController] = [:]

    override func loadView() {
        background.material = .windowBackground
        background.state = .followsWindowActiveState
        background.blendingMode = .withinWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        view = background

        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = true
        background.addSubview(host)
        hostBottomToBackground = host.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        hostBottomToBackground.isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        launchBar.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(launchBar)
        background.addSubview(launchBar.view)
        hostBottomToBar = host.bottomAnchor.constraint(equalTo: launchBar.view.topAnchor)
        NSLayoutConstraint.activate([
            launchBar.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            launchBar.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            launchBar.view.bottomAnchor.constraint(equalTo: background.safeAreaLayoutGuide.bottomAnchor),
            launchBar.view.heightAnchor.constraint(equalToConstant: RavenMetrics.launchBarHeight),
        ])
        launchBar.view.isHidden = true

        tracker.start { [weak self] in
            guard let self else { return }
            self.sync(for: self.workspace.destination)
            self.windowTitleSync()
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

    private func windowTitleSync() {
        guard let window = view.window else { return }
        if store.providers.isEmpty, workspace.destination.isLauncherPage {
            window.title = "Raven"
            window.subtitle = ""
            return
        }
        window.title = workspace.title
        window.subtitle = workspace.subtitle
    }

    private func sync(for destination: Destination) {
        let barVisible = destination.isLauncherPage && !store.providers.isEmpty
        launchBar.view.isHidden = !barVisible
        let pinnedToBar = hostBottomToBar.isActive
        if barVisible == pinnedToBar {
            // constraint state already matches
        } else if barVisible {
            hostBottomToBackground.isActive = false
            hostBottomToBar.isActive = true
        } else {
            hostBottomToBar.isActive = false
            hostBottomToBackground.isActive = true
        }
        if !barVisible, destination.isLauncherPage {
            install(WelcomeViewController())
            return
        }
        switch destination {
        case .recents:
            install(RecentsViewController())
        case .library, .pinned, .provider:
            if current is ModelListViewController { return }
            install(ModelListViewController())
        default:
            install(panelController(for: destination))
        }
    }

    private func install(_ controller: NSViewController) {
        guard !(current is WelcomeViewController && controller is WelcomeViewController) else { return }
        if current !== controller {
            let outgoing = current
            outgoing?.view.removeFromSuperview()
            outgoing?.removeFromParent()
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(controller)
            host.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            current = controller
            controller.view.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                controller.view.animator().alphaValue = 1
            })
        } else {
            guard controller.view.superview == nil else { return }
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
    }

    private func panelController(for destination: Destination) -> NSViewController {
        if let cached = panelControllers[destination] { return cached }
        let created = switch destination {
        case .overview: OverviewViewController()
        case .usage: UsageViewController()
        case .accounts: AccountsViewController()
        case .providersPage: ProvidersPanelViewController()
        case .pricing: PricingViewController()
        default: UnavailablePanelViewController(destination: destination)
        }
        panelControllers[destination] = created
        return created
    }
}

@MainActor
final class UnavailablePanelViewController: NSViewController {
    init(destination: Destination) {
        super.init(nibName: nil, bundle: nil)
        let unavailable = UnavailableView(symbol: destination.symbol,
                                          title: destination.launcherTitle,
                                          description: nil)
        view.addSubview(unavailable)
        NSLayoutConstraint.activate([
            unavailable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unavailable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            unavailable.topAnchor.constraint(equalTo: view.topAnchor),
            unavailable.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
    }
}

nonisolated extension Destination {
    var launcherTitle: String {
        switch self {
        case .library: "All Models"
        case .pinned: "Pinned"
        case .recents: "Recents"
        case .provider: "Provider"
        case .overview: "Overview"
        case .usage: "Usage"
        case .accounts: "Accounts"
        case .providersPage: "Models"
        case .pricing: "Pricing"
        }
    }
}
