import Foundation
import os

/// 重さの計測の印（既定は無効）。ラベルを StaticString に限るのは、本文・パス・sessionId を混ぜられないようにするため。
public enum PerfProbe {
    /// 有効か。無効の時の呼び出しはこれを見るだけで返す。
    nonisolated(unsafe) public private(set) static var isEnabled = false
    nonisolated(unsafe) static var collector: PerfCollector?

    /// 有効にする印のファイル。
    public static var markerURL: URL { DeckPaths.logs.appendingPathComponent("perf.on") }
    /// 書き出す先。
    public static var logURL: URL { DeckPaths.logs.appendingPathComponent("perf.log") }

    /// 環境変数 `CLAUDE_DECK_PERF=1` か、印のファイルがあれば有効にする。
    public static func isRequested(environment: [String: String], marker: URL) -> Bool {
        environment["CLAUDE_DECK_PERF"] == "1" || FileManager.default.fileExists(atPath: marker.path)
    }

    /// 起動時に一度だけ呼ぶ。求められていなければ何もしない。
    public static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled, isRequested(environment: environment, marker: markerURL) else { return }
        let collector = PerfCollector(log: MenuOpsLog(url: logURL, keep: PerfCollector.maxLines))
        self.collector = collector
        isEnabled = true
        collector.start()
    }

    /// 10 秒ごとの行に添える文脈（メインで呼ぶ。数だけを返す）。
    public static func setContext(_ provider: @escaping @MainActor @Sendable () -> [(String, Int)]) {
        collector?.setContext(provider)
    }

    /// 区間を測る。
    @inline(__always)
    public static func measure<T>(_ label: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let span = begin(label)
        defer { end(span) }
        return try body()
    }

    /// 区間の始まり（無効なら nil）。`end` で閉じる。
    @inline(__always)
    public static func begin(_ label: StaticString) -> PerfSpan? {
        guard isEnabled, let collector else { return nil }
        return collector.begin(label)
    }

    /// 区間の終わり。`value` はバイト数・件数など（足し合わせる。無効の時は評価しない）。
    @inline(__always)
    public static func end(_ span: PerfSpan?, value: @autoclosure () -> Int = 0) {
        guard let span, let collector else { return }
        collector.end(span, value: value())
    }

    /// 回数を数える（時間は測らない）。`value` は件数など。
    @inline(__always)
    public static func count(_ label: StaticString, value: @autoclosure () -> Int = 0) {
        guard isEnabled, let collector else { return }
        collector.count(label, value: value())
    }
}

/// 測っている途中の区間。
public struct PerfSpan: Sendable {
    let label: StaticString
    let start: UInt64
    let state: OSSignpostIntervalState
}

/// 区間の集計と、メインの詰まりの見張りと、10 秒ごとの書き出し。
public final class PerfCollector: @unchecked Sendable {
    /// 残す行数。
    public static let maxLines = 3000
    /// 書き出しの間隔。
    static let flushInterval: TimeInterval = 10
    /// メインへ印を投げる間隔。
    static let stallInterval: TimeInterval = 0.1
    /// 詰まりとみなす遅れ。
    static let stallThresholdNs: UInt64 = 250_000_000

    struct Key: Hashable {
        let label: Int
        let main: Bool
    }

    struct Stat {
        let label: StaticString
        var count = 0
        var timed = false
        var totalNs: UInt64 = 0
        var maxNs: UInt64 = 0
        var value = 0
    }

    /// 書き出す 1 区間分（名前とスレッドでまとめた後）。
    struct Row: Equatable {
        let name: String
        let main: Bool
        var count: Int
        var timed: Bool
        var totalNs: UInt64
        var maxNs: UInt64
        var value: Int
    }

    let log: MenuOpsLog
    let signposter: OSSignposter
    private let lock = NSLock()
    private var stats: [Key: Stat] = [:]
    private var lags: [UInt64] = []
    private var context: (@MainActor @Sendable () -> [(String, Int)])?
    private let queue = DispatchQueue(label: "claude-deck.perf")
    private var timers: [DispatchSourceTimer] = []
    private var pingInFlight = false

    init(log: MenuOpsLog, signposter: OSSignposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "local.claude-deck",
                                                                      category: "perf")) {
        self.log = log
        self.signposter = signposter
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func key(_ label: StaticString, main: Bool) -> Key {
        let id = label.hasPointerRepresentation ? Int(bitPattern: label.utf8Start) : Int(label.unicodeScalar.value)
        return Key(label: id, main: main)
    }

    func setContext(_ provider: @escaping @MainActor @Sendable () -> [(String, Int)]) {
        lock.withLock { context = provider }
    }

    func begin(_ label: StaticString) -> PerfSpan {
        let state = signposter.beginInterval(label, id: signposter.makeSignpostID())
        return PerfSpan(label: label, start: Self.now(), state: state)
    }

    func end(_ span: PerfSpan, value: Int) {
        let elapsed = Self.now() &- span.start
        signposter.endInterval(span.label, span.state)
        add(span.label, ns: elapsed, value: value, main: pthread_main_np() != 0)
    }

    func count(_ label: StaticString, value: Int) {
        signposter.emitEvent(label)
        add(label, ns: nil, value: value, main: pthread_main_np() != 0)
    }

    func add(_ label: StaticString, ns: UInt64?, value: Int, main: Bool) {
        let key = Self.key(label, main: main)
        lock.withLock {
            var stat = stats[key] ?? Stat(label: label)
            stat.count += 1
            stat.value &+= value
            if let ns {
                stat.timed = true
                stat.totalNs &+= ns
                stat.maxNs = max(stat.maxNs, ns)
            }
            stats[key] = stat
        }
    }

    func addLag(_ ns: UInt64) {
        lock.withLock { lags.append(ns) }
    }

    /// 溜めた分を取り出して空にする（同じ名前・スレッドはまとめ、メインの合計時間の多い順）。
    func drain() -> (rows: [Row], lags: [UInt64]) {
        let (taken, takenLags) = lock.withLock {
            defer { stats = [:]; lags = [] }
            return (stats, lags)
        }
        var merged: [String: Row] = [:]
        for (key, stat) in taken {
            let name = stat.label.description
            let id = "\(key.main ? "m" : "b"):\(name)"
            var row = merged[id] ?? Row(name: name, main: key.main, count: 0, timed: false, totalNs: 0, maxNs: 0, value: 0)
            row.count += stat.count
            row.timed = row.timed || stat.timed
            row.totalNs &+= stat.totalNs
            row.maxNs = max(row.maxNs, stat.maxNs)
            row.value &+= stat.value
            merged[id] = row
        }
        let rows = merged.values.sorted {
            ($0.main ? 1 : 0, $0.totalNs, $0.count, $1.name) > ($1.main ? 1 : 0, $1.totalNs, $1.count, $0.name)
        }
        return (rows, takenLags)
    }

    /// 1 回分の行（`ctx` → `stall` → 区間）。
    static func lines(rows: [Row], lags: [UInt64], context: [(String, Int)], seconds: TimeInterval) -> [(String, [(String, String)])] {
        var result: [(String, [(String, String)])] = []
        result.append(("ctx", [("sec", format(seconds))] + context.map { ($0.0, String($0.1)) }))
        let sorted = lags.sorted()
        let over = lags.filter { $0 >= stallThresholdNs }.count
        result.append(("stall", [("samples", String(lags.count)), ("p50_ms", ms(percentile(sorted, 0.5))),
                                 ("p95_ms", ms(percentile(sorted, 0.95))), ("max_ms", ms(sorted.last ?? 0)),
                                 ("over250", String(over))]))
        for row in rows {
            var fields: [(String, String)] = [("name", row.name), ("thread", row.main ? "main" : "bg"), ("n", String(row.count))]
            if row.timed {
                fields += [("total_ms", ms(row.totalNs)), ("max_ms", ms(row.maxNs))]
            }
            if row.value != 0 { fields.append(("value", String(row.value))) }
            result.append((row.timed ? "span" : "count", fields))
        }
        return result
    }

    static func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }

    static func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1_000_000) }
    static func format(_ seconds: TimeInterval) -> String { String(format: "%.1f", seconds) }

    /// 取り出して書く（文脈はメインで取る）。
    func flush(seconds: TimeInterval) {
        let drained = drain()
        let provider = lock.withLock { context }
        let write: @Sendable ([(String, Int)]) -> Void = { [log] context in
            let date = Date()
            for (event, fields) in Self.lines(rows: drained.rows, lags: drained.lags, context: context, seconds: seconds) {
                log.record(event, fields, date: date)
            }
        }
        guard let provider else { return write([]) }
        DispatchQueue.main.async { write(MainActor.assumeIsolated { provider() }) }
    }

    func start() {
        let flushTimer = DispatchSource.makeTimerSource(queue: queue)
        flushTimer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        flushTimer.setEventHandler { [weak self] in self?.flush(seconds: Self.flushInterval) }
        // 1 つずつ投げる（詰まった間に溜めると 1 回の詰まりを何度も数える）。
        let pingTimer = DispatchSource.makeTimerSource(queue: queue)
        pingTimer.schedule(deadline: .now() + Self.stallInterval, repeating: Self.stallInterval)
        pingTimer.setEventHandler { [weak self] in self?.ping() }
        timers = [flushTimer, pingTimer]
        timers.forEach { $0.resume() }
    }

    func stop() {
        queue.sync {
            timers.forEach { $0.cancel() }
            timers = []
        }
    }

    private func ping() {
        guard !pingInFlight else { return }
        pingInFlight = true
        let sent = Self.now()
        DispatchQueue.main.async { [weak self] in
            let lag = Self.now() &- sent
            guard let self else { return }
            self.queue.async {
                self.addLag(lag)
                self.pingInFlight = false
            }
        }
    }
}
