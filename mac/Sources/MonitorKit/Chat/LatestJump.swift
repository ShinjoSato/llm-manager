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

/// 「最新へ」のボタンを出すかと、離れている間に増えた会話の項目の数。
public struct LatestJump: Sendable, Equatable {
    /// これ以下なら一番下とみなす（付いていく判定と同じ幅）。
    public static let bottomTolerance: Double = 48
    /// ボタンを出す距離の下限。画面が低くても少しの揺れで出ないようにする。
    public static let minimumShowDistance: Double = 200

    public private(set) var showsButton = false
    /// 一番下を離れた時に出ていた項目の id。nil なら一番下にいる。
    public private(set) var baseline: Set<String>?

    public init() {}

    /// ボタンを出す距離。1 画面の半分か下限の大きい方。
    public static func showDistance(viewportHeight: Double) -> Double {
        max(minimumShowDistance, viewportHeight * 0.5)
    }

    public static func zone(contentHeight: Double, offsetY: Double, viewportHeight: Double) -> ScrollZone {
        let distance = contentHeight - (offsetY + viewportHeight)
        if distance <= bottomTolerance { return .bottom }
        return distance > showDistance(viewportHeight: viewportHeight) ? .far : .near
    }

    /// 段が変わった時に呼ぶ。`ids` はその時点で数える対象の項目の id。
    public mutating func enter(_ zone: ScrollZone, ids: [String]) {
        switch zone {
        case .bottom:
            reset()
        case .near:
            if baseline == nil { baseline = Set(ids) }
        case .far:
            if baseline == nil { baseline = Set(ids) }
            showsButton = true
        }
    }

    /// 一番下に戻った（押して移った・ルームが替わった）ので数を 0 にしてボタンを消す。
    public mutating func reset() {
        showsButton = false
        baseline = nil
    }

    /// 離れた時点の後に増えた項目の数。ボタンを出していない間は 0。
    public func newCount(ids: [String]) -> Int {
        guard showsButton, let baseline else { return 0 }
        return ids.reduce(0) { $0 + (baseline.contains($1) ? 0 : 1) }
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
}
