import AppKit

/// メインの付属の別ウィンドウ（ルーム・吹き出し）に共通の作り方・置き方・閉じ方。
@MainActor
enum DetachedWindow {
    /// 同じ `tabbingIdentifier` のウィンドウ同士だけを macOS のタブにまとめられるようにする（メインは混ぜない）。
    static func make(size: NSSize, minSize: NSSize, tabbingIdentifier: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.backgroundColor = ChatTheme.nsBackground
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = .automatic
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        return window
    }

    /// 同じ種類の別ウィンドウがあれば少しずらして重ね、無ければメインの右上に寄せる（メインの左の一覧になるべく重ねない）。
    static func place(_ window: NSWindow, siblings: some Sequence<NSWindow>, main: NSWindow?) {
        let offset: CGFloat = 28
        let topLeft: NSPoint
        let screen: NSScreen?
        if let sibling = siblings.first(where: \.isVisible) {
            topLeft = NSPoint(x: sibling.frame.minX + offset, y: sibling.frame.maxY - offset)
            screen = sibling.screen
        } else if let main, main.isVisible {
            topLeft = NSPoint(x: main.frame.maxX - window.frame.width - offset, y: main.frame.maxY - offset)
            screen = main.screen
        } else {
            window.center()
            return
        }
        window.setFrameTopLeftPoint(topLeft)
        window.setFrame(window.constrainFrameRect(window.frame, to: screen ?? NSScreen.main), display: false)
    }

    /// 終了の保留中に隠したメインしか残らないと、最後のウィンドウを閉じた扱いでアプリが終わるので先に出し直す。
    static func revealMainIfLast(closing sender: NSWindow, siblings: some Sequence<NSWindow>, main: NSWindow?, show: () -> Void) {
        let othersVisible = siblings.contains { $0 !== sender && $0.isVisible }
        if !othersVisible, let main, !main.isVisible, !main.isMiniaturized { show() }
    }
}
