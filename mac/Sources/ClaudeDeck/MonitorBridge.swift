import Foundation
import MonitorKit

/// アプリ全体で 1 つだけ持つ monitor ストア。画面が増えても SSE 接続は 1 本にする。
@MainActor
enum MonitorBridge {
    /// 接続先は `CLAUDE_DECK_MONITOR_URL` / `CLAUDE_DECK_MONITOR_PORT`、デバッグ出力は `CLAUDE_DECK_MONITOR_DEBUG=1`。
    static let store = MonitorStore(client: MonitorClient(configuration: .fromEnvironment()))
}
