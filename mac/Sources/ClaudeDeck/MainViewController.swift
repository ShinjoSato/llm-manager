import AppKit
import SwiftUI

/// メインウィンドウの中身。チャット画面（SwiftUI）を AppKit に載せる。
final class MainViewController: NSViewController {
    let model = ChatModel(store: MonitorBridge.store)

    override func loadView() {
        let hosting = NSHostingView(rootView: ChatRootView(model: model) { StagePanel(model: model) })
        hosting.frame = NSRect(x: 0, y: 0, width: 1240, height: 780)
        view = hosting
    }
}
