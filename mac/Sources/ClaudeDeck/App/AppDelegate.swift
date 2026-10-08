import AppKit
import MonitorKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var main: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        AppearanceSettings.shared.apply()
        MonitorBridge.start()
        LimitWatch.shared.start()
        // チャット欄の変換中に設定の保存を止めないよう、設定画面がキーの時だけ見る。
        SettingsStore.shared.isComposing = {
            guard let window = NSApp.keyWindow, SettingsWindow.owns(window) else { return false }
            return (window.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        }
        SettingsStore.shared.startWatching()
        LinkVisitStore.shared.start()

        let main = MainViewController()
        self.main = main
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "claude-deck"
        window.backgroundColor = ChatTheme.nsBackground
        window.titlebarAppearsTransparent = true
        window.contentViewController = main
        // 幅は一覧の幅に応じて画面側（`ListPaneWindowSync`）が掛け直す。
        window.contentMinSize = NSSize(width: ListPaneWidth.minimumWindowWidth(listWidth: ListPaneWidth.standard), height: 520)
        window.setFrameAutosaveName("ClaudeDeckChatWindow")
        window.center()
        // 終了を取り消した時に出し直せるよう、閉じても解放しない。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        QuitCoordinator.shared.showMainWindow = { [weak self] in self?.window.makeKeyAndOrderFront(nil) }
        // 画面のモデルを渡した後に開く（操作の受け手が揃ってから）。既定は無効。
        RemoteAccessController.shared.startIfEnabled()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitCoordinator.shared.shouldTerminate() }
    }

    /// 最後のウィンドウを閉じると終了するので、閉じる前に終了の確認を通す（取り消したらウィンドウを残す）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let others = NSApp.windows.contains { $0 !== sender && $0.isVisible && $0.canBecomeMain }
        guard sender === window, !others else { return true }
        // 終了の保留中に閉じても待ちは続ける（確認なしで中断しない）。Dock から出し直せる。
        if QuitCoordinator.shared.isWaiting {
            sender.orderOut(nil)
            return false
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // ホスト中の claude は終了で PTY ごと閉じるので、その前の状態を書き切る（正常な終了なので再開中の印は外す）。
            main?.model.restorer.saveOnTermination()
            SettingsStore.shared.flushPending(force: true)
            SettingsStore.shared.stopWatching()
            // 開発サーバーと mcpbridge はアプリの外で動き続けないよう、プロセスグループごと止め切ってから終える。
            DevServerStore.shared.stopAllBlocking()
            IOSPreviewService.shared.stopAllBlocking()
        }
        RemoteAccessController.shared.shutdown()
        AttentionNotifier.shared.stop()
        MonitorBridge.stop()
    }

    // MARK: - メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

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

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "スクリーンショットを保存",
                         action: #selector(captureScreenshot),
                         keyEquivalent: "s")
        fileMenuItem.submenu = fileMenu

        // コピー・貼り付けは標準のセレクタで、応答チェーンの先頭（文字欄）に任せる。
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

    /// ウィンドウの中身を PNG でデスクトップに保存し、クリップボードにも写す（自前のビューを描くので画面収録の許可は要らない）。
    @MainActor @objc private func captureScreenshot() {
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

        if let image = NSImage(data: data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }

        SystemActions.revealInFinder(url)
    }
}
