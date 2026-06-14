import AppKit

/// サイドバー（プロジェクト一覧）+ タブ（端末）の2ペイン構成。
final class MainSplitViewController: NSSplitViewController {

    private let sidebar = SidebarViewController()
    private let tiles = TileContainerViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        addSplitViewItem(sidebarItem)

        let mainItem = NSSplitViewItem(viewController: tiles)
        addSplitViewItem(mainItem)

        sidebar.onSelect = { [weak self] project in
            self?.tiles.openOrFocus(project)
        }
        sidebar.reload()
    }
}
