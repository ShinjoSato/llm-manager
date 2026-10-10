import AppKit
import SwiftUI
import MonitorKit

/// Claude の返答の吹き出しの別ウィンドウ。開いた時点の本文の写しを持ち、印ごとに 1 枚の NSWindow を持つ。
@MainActor
final class BubbleWindows: NSObject, NSWindowDelegate {
    /// 吹き出しのウィンドウ同士だけを macOS のタブにまとめる（ルームの別ウィンドウとは混ぜない）。
    static let tabbingIdentifier = "ClaudeDeckBubbleWindow"

    private var bubbles = DetachedBubbles()
    private var windows: [UUID: NSWindow] = [:]
    private weak var mainWindow: NSWindow?
    private let showMainWindow: () -> Void
    /// 他の種類の別ウィンドウ（残っていればメインを出し直さなくてもアプリは終わらない）。
    var peers: () -> [NSWindow] = { [] }

    init(model: ChatModel, mainWindow: NSWindow, showMainWindow: @escaping () -> Void) {
        self.mainWindow = mainWindow
        self.showMainWindow = showMainWindow
        super.init()
        model.presentBubbleWindow = { [weak self] snapshot in self?.present(snapshot) }
    }

    var allWindows: [NSWindow] { Array(windows.values) }

    func owns(_ window: NSWindow?) -> Bool {
        token(of: window) != nil
    }

    private func token(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { $0.value === window }?.key
    }

    private func present(_ snapshot: BubbleSnapshot) {
        let token = bubbles.open(snapshot).token
        if let window = windows[token] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let shown = bubbles.snapshot(for: token) ?? snapshot
        let window = DetachedWindow.make(size: NSSize(width: 620, height: 640), minSize: NSSize(width: 360, height: 240),
                                         tabbingIdentifier: Self.tabbingIdentifier)
        window.title = shown.title(time: ChatTime.clock(shown.at.map(Date.init(epochMillis:))))
        window.contentView = NSHostingView(rootView: BubbleWindowView(snapshot: shown))
        window.delegate = self
        DetachedWindow.place(window, siblings: windows.values, main: mainWindow)
        windows[token] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        DetachedWindow.revealMainIfLast(closing: sender, siblings: Array(windows.values) + peers(), main: mainWindow, show: showMainWindow)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let token = token(of: window) else { return }
        windows[token] = nil
        bubbles.close(token)
    }
}
