import AppKit
import MonitorKit

/// アプリ全体で 1 つだけ持つ monitor ストア。画面が増えても SSE 接続は 1 本にする。
@MainActor
enum MonitorBridge {
    /// 接続先は `CLAUDE_DECK_MONITOR_URL` / `CLAUDE_DECK_MONITOR_PORT`、デバッグ出力は `CLAUDE_DECK_MONITOR_DEBUG=1`。
    static let configuration = MonitorConfiguration.fromEnvironment()
    static let store = MonitorStore(client: MonitorClient(configuration: configuration))
    /// monitor の自動起動。状態は `launcher.phase` を見る（ログは `launcher.logURL`）。
    static let launcher = MonitorLauncher(
        configuration: configuration,
        monitorDirectory: AIManagerRoot.url?.appendingPathComponent("monitor")
    )

    private static var signalSources: [DispatchSourceSignal] = []

    /// launcher を動かしてから購読を始める。store は自分で再接続するので launcher の完了は待たない。
    static func start() {
        installTerminationSignals()
        launcher.onFailure = { failure in presentFailure(failure) }
        launcher.start()
        store.start()
    }

    /// 自分が起動した monitor だけを止める。
    static func shutdown() {
        launcher.stop()
    }

    /// SIGTERM / SIGINT では applicationWillTerminate が呼ばれず子が孤児になるので、通常の終了経路に乗せる。
    private static func installTerminationSignals() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func presentFailure(_ failure: MonitorLaunchFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "monitor を自動起動できませんでした"
        alert.informativeText = (failure.errorDescription ?? "\(failure)")
            + "\n\nログ: \(launcher.logURL?.path ?? "-")"
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
