import Foundation

/// 左の一覧（ルーム / ディレクトリ共通）の幅。境界をドラッグして変え、UserDefaults に持つ。
public enum ListPaneWidth {
    public static let defaultsKey = "roomList.width"
    public static let standard: Double = 312
    public static let minimum: Double = 240
    public static let maximum: Double = 480
    /// 中央（会話・ディレクトリの詳細）が保つ幅。
    public static let centerMinimum: Double = 420

    /// 保存値を範囲に収める。数でない値は既定に戻す。
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        return min(max(value, minimum), maximum)
    }

    /// ドラッグの移動量を足した幅。広げるのは中央が最小幅を割らない分まで、狭めるのは一覧の最小まで。
    public static func dragged(start: Double, translation: Double, current: Double, centerWidth: Double) -> Double {
        let proposed = start + translation
        guard proposed.isFinite else { return clamped(current) }
        let slack = centerWidth.isFinite ? max(centerWidth - centerMinimum, 0) : 0
        let upper = max(minimum, min(maximum, clamped(current) + slack))
        return min(max(proposed, minimum), upper)
    }
}
