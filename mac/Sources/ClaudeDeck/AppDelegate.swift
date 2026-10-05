import AppKit
import MonitorKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        MonitorBridge.start()
        SettingsStore.shared.isComposing = {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        }
        SettingsStore.shared.startWatching()

        let main = MainViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "claude-deck"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ChatTheme.nsBackground
        window.titlebarAppearsTransparent = true
        window.contentViewController = main
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.setFrameAutosaveName("ClaudeDeckChatWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        // 画面のモデルを渡した後に開く（操作の受け手が揃ってから）。既定は無効。
        RemoteAccessController.shared.startIfEnabled()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SettingsStore.shared.flushPending(force: true)
            SettingsStore.shared.stopWatching()
        }
        RemoteAccessController.shared.shutdown()
        AttentionNotifier.shared.stop()
        MonitorBridge.stop()
    }

    // MARK: - メニュー（最小構成: アプリ / 編集）

    private func buildMenu() {
        let mainMenu = NSMenu()

        // アプリメニュー
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "claude-deck について", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "iPhone 連携…", action: #selector(showRemoteAccess), keyEquivalent: "")
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

    @MainActor @objc private func showSettings() {
        SettingsWindow.show(tab: nil)
    }

    @MainActor @objc private func showRemoteAccess() {
        SettingsWindow.show(tab: .remote)
    }

    // 監視を張れなかった時の取りこぼしを拾う（外で書き換えられていた時だけ読み直す）。
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { SettingsStore.shared.reloadIfChanged() }
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

        let name = "claude-deck-\(ChatTime.stamp(Date())).png"
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
