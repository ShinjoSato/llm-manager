import Foundation
import MonitorKit

// monitor への接続・再接続を GUI 無しで確かめる。
//   CLAUDE_DECK_MONITOR_URL=http://127.0.0.1:8799 swift run monitor-probe [秒数] [pid...]
// 渡した pid はアプリがホストする claude とみなして対応付けを表示する。

let args = Array(CommandLine.arguments.dropFirst())
let seconds = args.first.flatMap(Double.init) ?? 30
let pids = args.dropFirst().compactMap { Int32($0) }

var config = MonitorConfiguration.fromEnvironment()
config.debugLogging = true

let finished = DispatchSemaphore(value: 0)
Task { @MainActor in
    let store = MonitorStore(client: MonitorClient(configuration: config))
    for pid in pids { store.registerHostedProcess(pid: pid) }
    store.start()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    print("---- 終了時点のストア ----")
    print("connection: \(store.connection)  epoch: \(store.connectionEpoch)")
    print("sessions: \(store.sessions.count)  feed: \(store.feed.count)  permissions: \(store.permissions.count)")
    if let usage = store.usage {
        print("usage: 5h 残り \(usage.fiveHour.map { String(format: "%.0f%%", $0.remainingPercentage) } ?? "-") / 週 残り \(usage.sevenDay.map { String(format: "%.0f%%", $0.remainingPercentage) } ?? "-")")
    } else {
        print("usage: nil")
    }
    for pid in pids {
        let snapshot = store.session(forHostedPid: pid)
        print("hosted pid \(pid) → sessionId \(store.sessionId(forHostedPid: pid) ?? "未解決")  monitor: \(snapshot.map { "\($0.name) \($0.status.rawValue)" } ?? "未検出")")
    }
    print("external sessions: \(store.externalSessions.count)")
    store.stop()
    finished.signal()
}

// メインアクターを回すため、main スレッドを RunLoop で空けておく。
while finished.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
