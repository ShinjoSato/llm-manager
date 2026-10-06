import Foundation
import Observation
import MonitorKit

/// 公式の残量（`MonitorBridge.store.usage`）を見て、上限に達したらアプリでホストしている全端末を止める。
@MainActor
final class LimitWatch {
    static let shared = LimitWatch()

    private struct Entry { weak var terminal: ClaudeTerminalView? }
    private var entries: [Entry] = []
    private let file = LimitStateFile(url: LimitStateFile.defaultURL())
    private var latch: UsageLimitLatch
    private var observing = false
    private var savedRecord: LimitStateRecord?

    private init() {
        let record = file.load()
        savedRecord = record
        latch = UsageLimitLatch(restoring: record)
    }

    /// 起動時に残量の見張りを始める（到達の記録を書き続けるため、端末の登録を待たない）。
    func start() {
        guard !observing else { return }
        observing = true
        observe()
        evaluate()
    }

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

    /// 公式の残量で上限到達中か（覚えている到達と、前回の起動で書き残した到達のリセット前も含む）。新しい起動を始めない判断に使う。
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
        let reached = latch.update(with: MonitorBridge.store.usage)
        persist()
        guard reached else { return }
        entries.removeAll { $0.terminal == nil }
        for entry in entries { entry.terminal?.reachLimit() }
    }

    private func persist() {
        let record = latch.record
        guard record != savedRecord else { return }
        do {
            try file.save(record)
            savedRecord = record
        } catch {
            FileHandle.standardError.write(Data("[claude-deck] 上限到達の記録を書けませんでした（\(file.url.path)）\n".utf8))
        }
    }
}
