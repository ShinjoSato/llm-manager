import Foundation
import Observation
import MonitorKit

/// 公式の残量（`MonitorBridge.store.usage`）を見て、上限に達したらアプリでホストしている全端末を止める。
@MainActor
final class LimitWatch {
    static let shared = LimitWatch()

    private struct Entry { weak var terminal: ClaudeTerminalView? }
    private var entries: [Entry] = []
    private var latch = UsageLimitLatch()
    private var observing = false

    /// 起動した端末を登録する。到達中なら（リセット前に起動し直したものも）すぐ止める。
    func register(_ terminal: ClaudeTerminalView) {
        entries.removeAll { $0.terminal == nil }
        entries.append(Entry(terminal: terminal))
        if !observing {
            observing = true
            observe()
        }
        evaluate()
    }

    /// 公式の残量で上限到達中か（覚えている到達のリセット前も含む）。新しい起動を始めない判断に使う。
    var isLimitReached: Bool {
        var copy = latch
        return copy.update(with: MonitorBridge.store.usage)
    }

    private func observe() {
        withObservationTracking {
            _ = MonitorBridge.store.usage
        } onChange: {
            // onChange は値が変わる直前に呼ばれるので、反映後に読み直す。
            Task { @MainActor in
                LimitWatch.shared.evaluate()
                LimitWatch.shared.observe()
            }
        }
    }

    private func evaluate() {
        guard latch.update(with: MonitorBridge.store.usage) else { return }
        entries.removeAll { $0.terminal == nil }
        for entry in entries { entry.terminal?.reachLimit() }
    }
}
