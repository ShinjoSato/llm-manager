import AppKit
import MonitorKit

/// アプリ全体で 1 つだけ持つ監視ストア。セッション監視・会話・フックの受け口（:8766）はアプリの中で動く。
@MainActor
enum MonitorBridge {
    /// 読み取り元は `CLAUDE_HOME`、受け口のポートは `CLAUDE_DECK_SERVER_PORT`、デバッグ出力は `CLAUDE_DECK_MONITOR_DEBUG=1`。
    /// 使用量は statusLine（mac/scripts/statusline.sh）が書く Application Support の usage.json。
    static let configuration = MonitorConfiguration.fromEnvironment()
    static let store = MonitorStore(configuration: configuration)

    private static var signalSources: [DispatchSourceSignal] = []

    static func start() {
        installTerminationSignals()
        store.start()
    }

    static func stop() {
        store.stop()
    }

    /// SIGTERM / SIGINT では applicationWillTerminate が呼ばれないので、通常の終了経路に乗せる。
    private static func installTerminationSignals() {
        guard signalSources.isEmpty else { return }
        TerminationSignals.installNoopHandlers(for: [SIGTERM, SIGINT])
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
