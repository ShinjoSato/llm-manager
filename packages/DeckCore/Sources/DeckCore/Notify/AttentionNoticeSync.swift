import Foundation

/// 知らせの置き場（mac では CloudKit のプライベート DB）。試験では偽物に差し替える。
public protocol AttentionNoticeStore: Sendable {
    func save(_ notice: AttentionNotice) async throws
    /// 既に無いものを消すのは成功として扱う。
    func delete(recordName: String) async throws
}

/// 書いた知らせの名前を覚えておく所。終了の前に消せなかった知らせを、次の起動で消すために使う。
public protocol AttentionNoticeLedger: Sendable {
    func load() -> [String]
    func store(_ names: [String])
}

public final class UserDefaultsNoticeLedger: AttentionNoticeLedger, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "attentionNotice.written") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String] { defaults.stringArray(forKey: key) ?? [] }
    public func store(_ names: [String]) { defaults.set(names, forKey: key) }
}

/// 書き込みの順番待ちと静かな再試行。時計は呼び手が `tick` で進める（中で眠らない）。
@MainActor
public final class AttentionNoticeSync {
    public enum Status: Equatable, Sendable {
        /// まだ何も書いていない。
        case idle
        case synced(at: Date)
        /// 失敗したので `retryAt` に送り直す。
        case retrying(failures: Int, retryAt: Date, message: String)
    }

    enum Op: Equatable {
        case save(AttentionNotice)
        case delete
    }

    public private(set) var status: Status = .idle
    /// recordName → まだ送っていない操作（届いた順）。
    private(set) var pending: [(name: String, op: Op)] = []
    private(set) var written: Set<String>
    private var failures = 0
    private var retryAt: Date?
    private var draining = false
    /// 送っている最中の名前。
    private var inFlight: String?
    private let store: AttentionNoticeStore
    private let ledger: AttentionNoticeLedger

    public init(store: AttentionNoticeStore, ledger: AttentionNoticeLedger) {
        self.store = store
        self.ledger = ledger
        written = Set(ledger.load())
        // 前回の起動で書いたまま残っている知らせは、もう誰も消さないので先に消す。
        for name in written.sorted() { pending.append((name, .delete)) }
    }

    public var pendingCount: Int { pending.count }

    public func submit(_ changes: [AttentionNoticePlanner.Change]) {
        for change in changes {
            switch change {
            case .save(let notice):
                pending.removeAll { $0.name == notice.recordName }
                pending.append((notice.recordName, .save(notice)))
            case .delete(let name):
                let unsent = inFlight != name && pending.contains { $0.name == name && $0.op != .delete }
                pending.removeAll { $0.name == name }
                // まだ書いていないなら、書かずに済ませる（書いてから消すと通知だけ届く）。
                if unsent && !written.contains(name) { continue }
                pending.append((name, .delete))
            }
        }
    }

    /// 送れるものを順に送る。失敗したらそこで止め、間隔を空けて送り直す。
    public func tick(now: Date = Date()) async {
        guard !draining, !pending.isEmpty else { return }
        if let retryAt, now < retryAt { return }
        draining = true
        defer { draining = false }
        while let (name, op) = pending.first {
            inFlight = name
            defer { inFlight = nil }
            do {
                switch op {
                case .save(let notice):
                    try await store.save(notice)
                    written.insert(name)
                case .delete:
                    try await store.delete(recordName: name)
                    written.remove(name)
                }
                ledger.store(written.sorted())
                // 送っている間に同じ名前の操作が入れ替わっていたら、新しい方を残す。
                if let index = pending.firstIndex(where: { $0.name == name }), pending[index].op == op {
                    pending.remove(at: index)
                }
                failures = 0
                retryAt = nil
                status = .synced(at: now)
            } catch {
                failures += 1
                let at = now.addingTimeInterval(Self.backoff(failures))
                retryAt = at
                status = .retrying(failures: failures, retryAt: at, message: Self.describe(error))
                return
            }
        }
    }

    /// 2, 4, 8 … 秒、最大 5 分。
    static func backoff(_ failures: Int) -> TimeInterval {
        min(300, pow(2, Double(min(failures, 9))))
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}
