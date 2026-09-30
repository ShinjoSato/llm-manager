import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let split = MainSplitViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "claude-deck"
        window.contentViewController = split
        window.setFrameAutosaveName("ClaudeDeckMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - メニュー（最小構成: アプリ / 編集）

    private func buildMenu() {
        let mainMenu = NSMenu()

        // アプリメニュー
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "claude-deck について", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "claude-deck を終了",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // ファイルメニュー（スクリーンショット）
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "スクリーンショットを保存",
                         action: #selector(captureScreenshot),
                         keyEquivalent: "s")
        fileMenuItem.submenu = fileMenu

        // 編集メニュー（端末の選択コピー/貼り付け用に標準セレクタを配線）
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - スクリーンショット

    /// ウィンドウの内容を PNG で撮影し、デスクトップに保存 + クリップボードにコピー + Finder で表示。
    /// 自前のビュー階層を描画するため、画面収録権限は不要。
    @objc private func captureScreenshot() {
        guard let contentView = window?.contentView else { return }
        let rect = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return }
        contentView.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }

        // ファイル名（撮影時刻）
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "claude-deck-\(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent(name)

        do {
            try data.write(to: url)
        } catch {
            NSSound.beep()
            return
        }

        // クリップボードへも画像をコピー
        if let image = NSImage(data: data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }

        // Finder で保存先を表示
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
