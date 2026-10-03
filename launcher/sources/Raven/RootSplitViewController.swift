import AppKit

@MainActor
final class RootSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let detail = DetailContainerViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        detailItem.canCollapse = false
        addSplitViewItem(detailItem)
    }
}
