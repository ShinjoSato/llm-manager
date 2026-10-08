import AppKit

/// 載ったウィンドウの伸縮を受ける NSView（SwiftUI からウィンドウの幅を読むため）。載った直後にも 1 回呼ぶ。
class WindowResizeView: NSView {
    private var observer: NSObjectProtocol?

    /// ウィンドウに載った時（最初の `windowDidResize` の前）。
    func didAttach(to window: NSWindow) {}

    /// ウィンドウの大きさが変わった時と、載った直後。
    func windowDidResize(_ window: NSWindow) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.windowDidResize(window)
            }
        }
        didAttach(to: window)
        windowDidResize(window)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
