import AppKit

@MainActor
class PanelScrollViewController: NSViewController {
    let scroll = NSScrollView()
    let stack = NSStackView()
    var onPullToRefresh: (() -> Void)?

    var maxContentWidth: CGFloat = RavenMetrics.maxPanelWidth

    override func loadView() {
        view = NSView()
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = RavenMetrics.spacing4
        stack.edgeInsets = NSEdgeInsets(top: RavenMetrics.spacing4,
                                        left: RavenMetrics.contentMargin,
                                        bottom: RavenMetrics.spacing6,
                                        right: RavenMetrics.contentMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        let guide = view.safeAreaLayoutGuide
        let capWidth = maxContentWidth + 2 * RavenMetrics.contentMargin
        let trackWidth = stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        trackWidth.priority = .defaultHigh
        let floorWidth = stack.widthAnchor.constraint(greaterThanOrEqualToConstant: capWidth)
        floorWidth.priority = NSLayoutConstraint.Priority(700)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            trackWidth,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: capWidth),
            floorWidth,
            stack.centerXAnchor.constraint(equalTo: scroll.contentView.centerXAnchor),
        ])

        configureRefresh()
    }

    private var refreshController: NSRefreshController?

    private func configureRefresh() {
        guard #available(macOS 27.0, *) else { return }
        let controller = NSRefreshController()
        controller.target = self
        controller.action = #selector(pulledToRefresh)
        scroll.refreshController = controller
        refreshController = controller
    }

    @objc private func pulledToRefresh() {
        onPullToRefresh?()
    }

    func endRefreshing() {
        refreshController?.endRefreshing()
    }

    func addContent(_ views: [NSView]) {
        for subview in views {
            subview.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(subview)
        }
    }

    func addContent(_ views: NSView...) {
        addContent(views)
    }

    func insertContent(_ view: NSView, at index: Int) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(view, at: index)
    }

    func addFullWidth(_ subview: NSView) {
        addContent([subview])
    }
}

@MainActor
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
