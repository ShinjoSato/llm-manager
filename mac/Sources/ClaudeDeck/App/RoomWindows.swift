import AppKit
import SwiftUI
import MonitorKit

/// ルームの別ウィンドウ。開いているルームは `ChatModel.detached` が持ち、ここは印ごとに 1 枚の NSWindow を持つだけ。
@MainActor
final class RoomWindows: NSObject, NSWindowDelegate {
    /// 別ウィンドウ同士だけを macOS のタブにまとめられるようにする（メインは混ぜない）。
    static let tabbingIdentifier = "ClaudeDeckRoomWindow"

    private let model: ChatModel
    private var windows: [UUID: NSWindow] = [:]
    private weak var mainWindow: NSWindow?
    private let showMainWindow: () -> Void

    init(model: ChatModel, mainWindow: NSWindow, showMainWindow: @escaping () -> Void) {
        self.model = model
        self.mainWindow = mainWindow
        self.showMainWindow = showMainWindow
        super.init()
        model.presentRoomWindow = { [weak self] token in self?.present(token) }
        model.dismissRoomWindow = { [weak self] token in self?.windows[token]?.close() }
        model.alerts.keyRoomWindow = { [weak self] in self?.token(of: NSApp.keyWindow) }
    }

    func owns(_ window: NSWindow?) -> Bool {
        token(of: window) != nil
    }

    private func token(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { $0.value === window }?.key
    }

    private func present(_ token: UUID) {
        if let window = windows[token] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = model.detached.room(for: token).flatMap(model.room(id:))?.name ?? "ルーム"
        window.backgroundColor = ChatTheme.nsBackground
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .automatic
        window.contentMinSize = NSSize(width: ListPaneWidth.centerMinimum, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RoomWindowView(model: model, token: token) { [weak window] title in
            window?.title = title
        })
        window.delegate = self
        place(window)
        windows[token] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 他の別ウィンドウがあれば少しずらして重ね、無ければメインの右上に寄せる（メインの左の一覧になるべく重ねない）。
    private func place(_ window: NSWindow) {
        let offset: CGFloat = 28
        let topLeft: NSPoint
        let screen: NSScreen?
        if let sibling = windows.values.first(where: \.isVisible) {
            topLeft = NSPoint(x: sibling.frame.minX + offset, y: sibling.frame.maxY - offset)
            screen = sibling.screen
        } else if let main = mainWindow, main.isVisible {
            topLeft = NSPoint(x: main.frame.maxX - window.frame.width - offset, y: main.frame.maxY - offset)
            screen = main.screen
        } else {
            window.center()
            return
        }
        window.setFrameTopLeftPoint(topLeft)
        window.setFrame(window.constrainFrameRect(window.frame, to: screen ?? NSScreen.main), display: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 終了の保留中に隠したメインしか残らないと、最後のウィンドウを閉じた扱いでアプリが終わるので先に出し直す。
        if let main = mainWindow, !main.isVisible, !main.isMiniaturized { showMainWindow() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let token = token(of: window) else { return }
        windows[token] = nil
        model.roomWindowClosed(token)
    }
}
