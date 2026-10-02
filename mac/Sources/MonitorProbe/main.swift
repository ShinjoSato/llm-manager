import Foundation
import MonitorKit

// アプリ内の監視を GUI 無しで確かめる。受け口（:8766）は既定で開かない。
//   swift run monitor-probe [秒数] [pid...]
//   CLAUDE_DECK_SERVER_PORT=8799 swift run monitor-probe 30   ← 受け口も試す時は別ポートで
// 渡した pid はアプリがホストする claude とみなして対応付けを表示する。

let args = Array(CommandLine.arguments.dropFirst())
let seconds = args.first.flatMap(Double.init) ?? 30
let pids = args.dropFirst().compactMap { Int32($0) }

var env = ProcessInfo.processInfo.environment
if env["CLAUDE_DECK_SERVER_PORT"] == nil { env["CLAUDE_DECK_SERVER_PORT"] = "off" }
/// アプリと同じ残量ファイル（`<ai-manager>/data/claude-usage.json`）を読む。ルートは `AI_MANAGER_ROOT` か cwd・実行ファイルから遡って探す。
func defaultUsageFile(_ env: [String: String]) -> URL? {
    let fm = FileManager.default
    let isRoot = { (url: URL) in fm.fileExists(atPath: url.appendingPathComponent("projects/registry.tsv").path) }
    if let raw = env["AI_MANAGER_ROOT"], !raw.isEmpty, isRoot(URL(fileURLWithPath: raw)) {
        return URL(fileURLWithPath: raw).appendingPathComponent("data/claude-usage.json")
    }
    var starts = [URL(fileURLWithPath: fm.currentDirectoryPath)]
    if let exe = Bundle.main.executableURL { starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
    for start in starts {
        var dir = start.standardizedFileURL
        while true {
            if isRoot(dir) { return dir.appendingPathComponent("data/claude-usage.json") }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
    }
    return nil
}

var config = MonitorConfiguration.fromEnvironment(env, defaultUsageFile: defaultUsageFile(env))
config.debugLogging = true
let probeConfig = config

let finished = DispatchSemaphore(value: 0)
Task { @MainActor in
    let store = MonitorStore(configuration: probeConfig)
    for pid in pids { store.registerHostedProcess(pid: pid) }
    store.start()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    print("---- 終了時点のストア ----")
    print("connection: \(store.connection)  server: \(store.serverState)")
    print("sessions: \(store.sessions.count)  feed: \(store.feed.count)  permissions: \(store.permissions.count)")
    for s in store.sessions {
        print("  \(s.name) [pid \(s.pid)] \(s.status.rawValue)/\(s.statusSource.rawValue) \(s.currentTool ?? "") \(s.title ?? "")")
    }
    if let usage = store.usage {
        print("usage: 5h 残り \(usage.fiveHour.map { String(format: "%.0f%%", $0.remainingPercentage) } ?? "-") / 週 残り \(usage.sevenDay.map { String(format: "%.0f%%", $0.remainingPercentage) } ?? "-")")
    } else {
        print("usage: nil")
    }
    for pid in pids {
        let snapshot = store.session(forHostedPid: pid)
        print("hosted pid \(pid) → sessionId \(store.sessionId(forHostedPid: pid) ?? "未解決")  監視: \(snapshot.map { "\($0.name) \($0.status.rawValue)" } ?? "未検出")")
    }
    print("external sessions: \(store.externalSessions.count)")
    store.stop()
    finished.signal()
}

// メインアクターを回すため、main スレッドを RunLoop で空けておく。
while finished.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
