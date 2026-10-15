import Foundation

/// カードの「送信中」の台帳。押したカードにだけ付けて次のカードに引き継がせず、`limit` で必ず外すため。
public struct PromptOperationBook: Sendable, Equatable {
    /// 送信中の上限。応答を確かめられないまま押せないカードを残さないため。
    public static let limit: TimeInterval = 12
    /// 送り終えてから同じカードを押せないままにする長さ（画面が描き替わるまで古いカードが今の画面と一致して見えるため）。
    public static let settle: TimeInterval = 1.5
    /// 期限の時計を遅らせてよい幅（タイマーをまとめられて上限を大きく超えないため）。
    public static let timerTolerance: Duration = .milliseconds(50)

    public struct Entry: Sendable, Equatable {
        /// 操作の印。後から外す時は自分の印の時だけ外す。
        public let token: UUID
        /// 押したカードの印。nil は特定のカードに付けない印（どのカードも送信中には見せないが、重ねての操作は断る）。
        public let identity: String?
        public let since: Date
        /// これを過ぎたら必ず外す。
        public var deadline: Date
        /// 送り終えた後に外す時刻。nil なら送っている最中。
        public var releaseAt: Date?
        /// 描き替え待ちの間、別のカードへの操作も断る（どのカードの画面が今のものか分からない時）。
        public var blocksAll = false

        public var isOperating: Bool { releaseAt == nil }

        /// 印が外れる時刻。
        public var until: Date { min(releaseAt ?? deadline, deadline) }
    }

    public enum Refusal: Error, Sendable, Equatable {
        /// 同じルームで別の操作を送っている最中。
        case operating
        /// 同じカードへの操作を送り終えたばかり（画面の描き替え待ち）。
        case settling
        /// 端末の画面から送ったキーの反映待ち。
        case keys
    }

    /// 期限を過ぎて外した印。`timedOut` は送っている最中のまま期限を迎えたもの。
    public struct Expired: Sendable, Equatable {
        public let key: String
        public let entry: Entry
        public var timedOut: Bool { entry.isOperating }
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// 今の印（期限を過ぎたものは無いものとして扱う）。
    public func entry(_ key: String, now: Date) -> Entry? {
        guard let entry = entries[key], entry.until > now else { return nil }
        return entry
    }

    /// `identity` のカードへの操作を始めてよいか。
    public func refusal(key: String, identity: String?, now: Date) -> Refusal? {
        guard let entry = entry(key, now: now) else { return nil }
        if entry.isOperating { return .operating }
        if entry.identity == nil { return .keys }
        return entry.blocksAll || entry.identity == identity ? .settling : nil
    }

    /// 送っている最中の印を付ける。断る時は理由を返す。
    public mutating func begin(key: String, identity: String?, now: Date) -> Result<UUID, Refusal> {
        if let refusal = refusal(key: key, identity: identity, now: now) { return .failure(refusal) }
        let token = UUID()
        entries[key] = Entry(token: token, identity: identity, since: now, deadline: now.addingTimeInterval(Self.limit), releaseAt: nil)
        return .success(token)
    }

    /// キーを送り終えた操作の印を、描き替え待ちの間だけ付ける。送っている最中の印は上書きしない（そちらの守りが先に外れるため）。
    @discardableResult
    public mutating func hold(key: String, identity: String?, blocksAll: Bool = false, now: Date) -> UUID {
        if let current = entry(key, now: now), current.isOperating { return current.token }
        let token = UUID()
        var entry = Entry(token: token, identity: identity, since: now, deadline: now.addingTimeInterval(Self.limit),
                          releaseAt: now.addingTimeInterval(Self.settle))
        entry.blocksAll = blocksAll
        entries[key] = entry
        return token
    }

    /// 送り終えた。自分の印の時だけ、描き替え待ちに移す（上限の間際でも描き替え待ちは削らない。削ると同じカードへ Enter が重なりうる）。
    @discardableResult
    public mutating func finish(key: String, token: UUID, now: Date) -> Bool {
        guard var entry = entries[key], entry.token == token else { return false }
        let releaseAt = now.addingTimeInterval(Self.settle)
        entry.releaseAt = releaseAt
        entry.deadline = max(entry.deadline, releaseAt)
        entries[key] = entry
        return true
    }

    /// 自分の印の時だけ外す。
    @discardableResult
    public mutating func release(key: String, token: UUID) -> Bool {
        guard entries[key]?.token == token else { return false }
        entries[key] = nil
        return true
    }

    /// `identity` のカードを送信中に見せるか。印が自分のカードのものの時だけ。
    public func isCardBusy(key: String, identity: String, now: Date) -> Bool {
        entry(key, now: now)?.identity == identity
    }

    /// `identity` のカードの送信中が外れる時刻（送信中でなければ nil）。
    public func busyUntil(key: String, identity: String, now: Date) -> Date? {
        guard let entry = entry(key, now: now), entry.identity == identity else { return nil }
        return entry.until
    }

    /// 何かの操作の印が付いている鍵。
    public func activeKeys(now: Date) -> Set<String> {
        Set(entries.compactMap { $0.value.until > now ? $0.key : nil })
    }

    /// 期限を過ぎた印を外して返す。
    public mutating func expire(now: Date) -> [Expired] {
        let ended = entries.filter { $0.value.until <= now }
        for key in ended.keys { entries[key] = nil }
        return ended.map { Expired(key: $0.key, entry: $0.value) }.sorted { $0.key < $1.key }
    }

    /// 次に印が外れる時刻。
    public var nextExpiry: Date? { entries.values.map(\.until).min() }
}

/// カードに数秒だけ出す一言。`identity` が nil ならそのルームのどのカードにも出す。
public struct PromptCardNotice: Sendable, Equatable {
    public var text: String
    public var identity: String?
    public var until: Date

    public init(text: String, identity: String?, until: Date) {
        self.text = text
        self.identity = identity
        self.until = until
    }

    public func shows(on identity: String, now: Date) -> Bool {
        until > now && (self.identity == nil || self.identity == identity)
    }
}

/// カードの印（中身から作る。❯ の位置は含めないので、移動の途中で別のカードにならない）。
public enum PromptCardIdentity {
    public static func menu(_ menu: MenuPrompt) -> String { "m\(menu.identity)" }
    public static func unreadable(_ menu: UnreadableMenu) -> String { "u\(menu.hashValue)" }
    /// 端末の権限プロンプトは同じ文面が続けて出うるので、表示の世代も入れる。
    public static func permission(_ prompt: PermissionPrompt, generation: Int) -> String {
        "p" + RemoteTerminalPermission.promptId(prompt, generation: generation)
    }
}

/// 結果を 1 回だけ渡す箱。完了と時間切れのどちらが先でも、受け手には最初の 1 回だけ届く。
@MainActor
public final class OnceDelivery<Value> {
    private var handler: ((Value) -> Void)?

    public init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    public var isDelivered: Bool { handler == nil }

    /// 最初の 1 回だけ渡して true を返す。
    @discardableResult
    public func deliver(_ value: Value) -> Bool {
        guard let handler else { return false }
        self.handler = nil
        handler(value)
        return true
    }

    /// `delay` 秒後にまだ渡していなければ `value` を渡す（完了の受け口が捨てられても時間切れは届くよう、箱を強く持つ）。
    public func deliver(after delay: TimeInterval, _ value: @escaping () -> Value) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay), tolerance: PromptOperationBook.timerTolerance)
            guard !self.isDelivered else { return }
            self.deliver(value())
        }
    }
}
