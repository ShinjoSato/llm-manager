import Foundation
import Observation

/// カードの送信中と一言の置き場。カードが自分の body で読み、親の描き直しに頼らず期限で外れるようにするため。
@MainActor
@Observable
public final class PromptCardBoard {
    public typealias Fields = [(String, String)]

    public private(set) var book = PromptOperationBook()
    public private(set) var notices: [String: PromptCardNotice] = [:]

    /// 応答を確かめられないまま上限を過ぎた時の一言。
    public static let timeoutNotice = "応答を確かめられませんでした。端末の画面で確かめてください。"
    /// 一言を出しておく長さ。
    public static let noticeDuration: TimeInterval = 6
    public static let timeoutNoticeDuration: TimeInterval = 10

    /// 操作の記録の書き先（本文は渡さない。鍵・印・番号だけ）。
    @ObservationIgnored public var log: (String, Fields) -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var sweepAt: Date?

    public init(clock: @escaping () -> Date = Date.init, log: @escaping (String, Fields) -> Void = { _, _ in }) {
        self.clock = clock
        self.log = log
    }

    // MARK: - 送信中の印

    /// 送っている最中の印を付ける。断ったら理由を一言で出す。
    public func begin(key: String, identity: String?) -> Result<UUID, PromptOperationBook.Refusal> {
        expireStale()
        let result = book.begin(key: key, identity: identity, now: clock())
        switch result {
        case .success(let token):
            log("busy+", [("key", key), ("card", identity ?? "-"), ("token", Self.short(token)), ("phase", "operating")])
            // 新しい操作を始めたら、前の操作の一言は古いので残さない。
            notices[key] = nil
            scheduleSweep()
        case .failure(let refusal):
            log("refuse", [("key", key), ("card", identity ?? "-"), ("reason", Self.name(refusal))])
            showNotice(Self.message(refusal), key: key)
        }
        return result
    }

    /// 始めてよいか（断る時は一言を出す）。キーを 1 つ送るだけの操作で使う。
    public func admit(key: String, identity: String?) -> Bool {
        expireStale()
        guard let refusal = book.refusal(key: key, identity: identity, now: clock()) else { return true }
        log("refuse", [("key", key), ("card", identity ?? "-"), ("reason", Self.name(refusal))])
        showNotice(Self.message(refusal), key: key)
        return false
    }

    /// キーを送り終えたカードを、描き替え待ちの間だけ送信中にする。
    @discardableResult
    public func hold(key: String, identity: String?) -> UUID {
        expireStale()
        let token = book.hold(key: key, identity: identity, now: clock())
        log("busy+", [("key", key), ("card", identity ?? "-"), ("token", Self.short(token)), ("phase", "settling")])
        scheduleSweep()
        return token
    }

    /// 送り終えた（自分の印の時だけ描き替え待ちに移す）。
    public func finish(key: String, token: UUID) {
        let moved = book.finish(key: key, token: token, now: clock())
        log("busy~", [("key", key), ("token", Self.short(token)), ("settling", moved ? "yes" : "stale")])
        scheduleSweep()
    }

    /// 自分の印の時だけ外す。
    public func release(key: String, token: UUID, reason: String) {
        let removed = book.release(key: key, token: token)
        log("busy-", [("key", key), ("token", Self.short(token)), ("reason", reason), ("removed", removed ? "yes" : "stale")])
    }

    /// 期限を過ぎた印を外す。送っている最中のまま期限を迎えたものには一言を出す。
    public func sweep() {
        expireStale()
        let now = clock()
        notices = notices.filter { $0.value.until > now }
        sweepAt = nil
        scheduleSweep()
    }

    /// 期限を過ぎた印を外す（掃除の予約より先に次の操作が来ても、時間切れを記録と一言に残すため）。
    private func expireStale() {
        for expired in book.expire(now: clock()) {
            log("busy-", [("key", expired.key), ("token", Self.short(expired.entry.token)),
                          ("reason", expired.timedOut ? "timeout" : "settled")])
            if expired.timedOut { showNotice(Self.timeoutNotice, key: expired.key, duration: Self.timeoutNoticeDuration) }
        }
    }

    // MARK: - カードから読む

    public func isCardBusy(key: String, identity: String) -> Bool {
        book.isCardBusy(key: key, identity: identity, now: clock())
    }

    public func notice(key: String, identity: String) -> String? {
        guard let notice = notices[key], notice.shows(on: identity, now: clock()) else { return nil }
        return notice.text
    }

    /// このカードの見た目が次に変わりうる時刻（送信中や一言が外れる時）。カードの時計に使う。
    public func nextChange(key: String, identity: String) -> Date? {
        let now = clock()
        let busy = book.busyUntil(key: key, identity: identity, now: now)
        let notice = notices[key].flatMap { $0.shows(on: identity, now: now) ? $0.until : nil }
        return [busy, notice].compactMap { $0 }.min()
    }

    /// 何かの操作の印が付いている鍵（iPhone の一覧の「送信中」と、端末へのキー送信の重なりの判定）。
    public var activeKeys: Set<String> { book.activeKeys(now: clock()) }

    /// カードを出した時の送信中の値を残す（引き継いでいないかを後から確かめるため）。
    public func cardAppeared(key: String, identity: String, kind: String) {
        log("card", [("key", key), ("card", identity), ("kind", kind), ("busy", isCardBusy(key: key, identity: identity) ? "yes" : "no")])
    }

    // MARK: - 一言

    public func showNotice(_ text: String, key: String, identity: String? = nil, duration: TimeInterval = PromptCardBoard.noticeDuration) {
        notices[key] = PromptCardNotice(text: text, identity: identity, until: clock().addingTimeInterval(duration))
        scheduleSweep()
    }

    /// 同じ一言が出ている時だけ消す（後から出た別の一言は残す）。
    public func clearNotice(_ text: String, key: String) {
        if notices[key]?.text == text { notices[key] = nil }
    }

    // MARK: - 時計

    /// 次に外れる時刻に掃除を予約する（既に早い予約があればそのまま）。
    private func scheduleSweep() {
        let next = ([book.nextExpiry] + notices.values.map { Optional($0.until) }).compactMap { $0 }.min()
        guard let next else { return }
        if let sweepAt, sweepAt <= next { return }
        sweepAt = next
        let delay = max(0, next.timeIntervalSince(clock())) + 0.05
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: PromptOperationBook.timerTolerance)
            guard let self, self.sweepAt == next else { return }
            self.sweep()
        }
    }

    static func short(_ token: UUID) -> String { String(token.uuidString.prefix(8)) }

    static func name(_ refusal: PromptOperationBook.Refusal) -> String {
        switch refusal {
        case .operating: return "operating"
        case .settling: return "settling"
        }
    }

    public static func message(_ refusal: PromptOperationBook.Refusal) -> String {
        switch refusal {
        case .operating: return "前の操作を送っているところです。終わってからもう一度押してください。"
        case .settling: return "このカードへの操作は送ったところです。端末の表示が替わるのを待っています。"
        }
    }
}
