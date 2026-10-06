import Foundation

/// 引き継ぎで別のルームへ移った後に、元のルーム宛てに届く取り込みの結果の届け先。結果が届くたびに消え、全部届けば空になる。
public struct RoomRedirects<Room: Hashable & Sendable, Job: Hashable & Sendable>: Sendable, Equatable {
    private var destinations: [Job: Room] = [:]

    public init() {}

    /// まだ届いていない結果の数。
    public var count: Int { destinations.count }
    public var isEmpty: Bool { destinations.isEmpty }

    /// `jobs` の結果を `room` へ届ける。もう一度移れば最後の移し先が勝つ。
    public mutating func redirect(_ jobs: some Sequence<Job>, to room: Room) {
        for job in jobs { destinations[job] = room }
    }

    /// `room` 宛てに届いた `job` の結果の届け先。付け替えが無ければ `room` のまま。
    /// 1 件の結果は 1 回しか届かないので、表からは消す。
    public mutating func resolve(_ job: Job, arrivedAt room: Room) -> Room {
        destinations.removeValue(forKey: job) ?? room
    }
}
