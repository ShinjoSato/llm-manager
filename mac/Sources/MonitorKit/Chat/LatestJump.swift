import Foundation

/// 会話の一覧が一番下からどれだけ離れているかの段。スクロールのたびではなく段が変わった時だけ画面に知らせるために使う。
public enum ScrollZone: Sendable, Equatable {
    /// 一番下（新着に付いていく）。
    case bottom
    /// 少しだけ離れている（ボタンの出し入れを変えない幅）。
    case near
    /// 十分に離れている（ボタンを出す）。
    case far
}

/// 新着に付いていくかと、「最新へ」のボタンを出すかと、離れている間に増えた会話の項目の数。
public struct LatestJump: Sendable, Equatable {
    /// これ以下なら一番下とみなす（付いていく判定と同じ幅）。
    public static let bottomTolerance: Double = 48
    /// ボタンを出す距離の下限。画面が低くても少しの揺れで出ないようにする。
    public static let minimumShowDistance: Double = 200

    public private(set) var showsButton = false
    /// 一番下を離れた時に出ていた項目の id。nil なら一番下にいる。
    public private(set) var baseline: Set<String>?
    /// 最後に知らされた段。
    public private(set) var zone: ScrollZone = .bottom
    /// ボタンを押して末尾へ動いている間の番号。動いている間は途中の段で付いていくのをやめない。
    public private(set) var jumping: Int?
    /// baseline のうち送信中の発話。記録に載ると別の id に差し替わるので、消えた分は新着から差し引く。
    private var baselineOutgoing: Set<String> = []
    private var generation = 0

    public init() {}

    /// 新着が届いたら末尾へ付いていくか。
    public var followsBottom: Bool { jumping != nil || zone == .bottom }

    /// ボタンを出す距離。1 画面の半分か下限の大きい方。
    public static func showDistance(viewportHeight: Double) -> Double {
        max(minimumShowDistance, viewportHeight * 0.5)
    }

    public static func zone(contentHeight: Double, offsetY: Double, viewportHeight: Double) -> ScrollZone {
        let distance = contentHeight - (offsetY + viewportHeight)
        if distance <= bottomTolerance { return .bottom }
        return distance > showDistance(viewportHeight: viewportHeight) ? .far : .near
    }

    /// 段が変わった時に呼ぶ。`entries` はその時点の会話の項目。
    public mutating func enter(_ zone: ScrollZone, entries: [ChatEntry]) {
        self.zone = zone
        if jumping != nil {
            if zone == .bottom { jumping = nil; clear() }
            return
        }
        apply(entries: entries)
    }

    /// ボタンを押した。ボタンを消して数を 0 にし、末尾に着くか `finishJump` まで付いていく扱いにする。
    @discardableResult
    public mutating func startJump() -> Int {
        generation += 1
        jumping = generation
        clear()
        return generation
    }

    /// 動きの上限の時間が来た。末尾に着けなかった時は今の段に合わせ直す。
    public mutating func finishJump(_ generation: Int, entries: [ChatEntry]) {
        guard jumping == generation else { return }
        jumping = nil
        apply(entries: entries)
    }

    /// ルームが替わって末尾から出し直す。
    public mutating func reset() {
        zone = .bottom
        jumping = nil
        clear()
    }

    /// 離れた時点の後に増えた項目の数。ボタンを出していない間は 0。
    public func newCount(entries: [ChatEntry]) -> Int {
        guard showsButton, let baseline else { return 0 }
        let ids = Self.countedIds(entries)
        let added = ids.reduce(0) { $0 + (baseline.contains($1) ? 0 : 1) }
        let replaced = baselineOutgoing.subtracting(ids).count
        return max(0, added - replaced)
    }

    /// 数える項目の id。吹き出しになる発話だけを数え、ツールだけの行（直前の発話に畳めなかったもの）は数えない。
    public static func countedIds(_ entries: [ChatEntry]) -> [String] {
        entries.compactMap { $0.role == .toolsOnly ? nil : $0.id }
    }

    /// ボタンに添える数の表記。0 は出さず、大きい数は丸める。
    public static func badge(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    private mutating func apply(entries: [ChatEntry]) {
        switch zone {
        case .bottom:
            clear()
        case .near, .far:
            if baseline == nil {
                baseline = Set(Self.countedIds(entries))
                baselineOutgoing = Set(entries.filter { $0.role == .outgoing }.map(\.id))
            }
            if zone == .far { showsButton = true }
        }
    }

    private mutating func clear() {
        showsButton = false
        baseline = nil
        baselineOutgoing = []
    }
}
