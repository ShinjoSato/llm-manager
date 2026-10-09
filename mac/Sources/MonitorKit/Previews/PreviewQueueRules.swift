import Foundation

/// 時間切れ・読み込み待ちが続く時に待ち行列を止める判定（Xcode が詰まっている時に同じ待ちを繰り返さないため）。
public struct PreviewStallCounter: Equatable, Sendable {
    public static let limit = 2
    private var count = 0

    public init() {}

    /// 1 件の結果を数える。続けて `limit` 回になったら true を返して数え直す。
    public mutating func record(_ failure: XcodeBridgeFailure?) -> Bool {
        switch failure {
        case .timedOut?, .packagesLoading?:
            count += 1
        default:
            count = 0
        }
        guard count >= Self.limit else { return false }
        count = 0
        return true
    }

    public static func message(_ failure: XcodeBridgeFailure) -> String {
        "時間切れ・読み込み待ちが続いたため、残りを描かずに止めました（\(failure.message)）。Xcode の様子を確かめてから描き直してください"
    }
}

/// 「iPhone のプレビュー」の節がどのプロジェクトで開いているか（閉じたら待ち行列を取りやめるため）。
public struct PreviewSectionPresence: Equatable, Sendable {
    private var counts: [UUID: Int] = [:]

    public init() {}

    public var anyOpen: Bool { !counts.isEmpty }

    public func isOpen(_ projectId: UUID) -> Bool { counts[projectId] != nil }

    public mutating func open(_ projectId: UUID) {
        counts[projectId, default: 0] += 1
    }

    /// 閉じる。そのプロジェクトの節がどこにも開いていなくなったら true。
    @discardableResult
    public mutating func close(_ projectId: UUID) -> Bool {
        guard let count = counts[projectId] else { return false }
        if count <= 1 {
            counts[projectId] = nil
            return true
        }
        counts[projectId] = count - 1
        return false
    }
}
