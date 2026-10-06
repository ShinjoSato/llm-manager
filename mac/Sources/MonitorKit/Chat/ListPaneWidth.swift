import Foundation

/// 左の一覧（ルーム / ディレクトリ共通）の幅。境界をドラッグして変え、UserDefaults に持つ。
public enum ListPaneWidth {
    public static let defaultsKey = "roomList.width"
    public static let standard: Double = 312
    public static let minimum: Double = 240
    public static let maximum: Double = 480
    /// 中央（会話・ディレクトリの詳細）が保つ幅。
    public static let centerMinimum: Double = 420
    /// 一覧と中央のほかに常に要る幅（切り替えバー 48 + 境界 3 本 + 畳んだステージパネル 36）。
    public static let fixedChrome: Double = 48 + 3 + 36

    /// 保存値を範囲に収める。数でない値は既定に戻す。
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        return min(max(value, minimum), maximum)
    }

    /// つかんだ時の幅に移動量を足した幅。広げるのはつかんだ時の中央が最小幅を割らない分まで、狭めるのは一覧の最小まで。
    public static func dragged(start: Double, translation: Double, centerWidth: Double) -> Double {
        let base = clamped(start)
        let proposed = base + translation
        guard proposed.isFinite else { return base }
        return min(max(proposed, minimum), upperBound(from: base, centerWidth: centerWidth))
    }

    /// ダブルクリックで既定に戻す幅。広げる時はドラッグと同じく中央が最小幅を割らない分まで。
    public static func reset(from current: Double, centerWidth: Double) -> Double {
        let base = clamped(current)
        return min(standard, max(base, upperBound(from: base, centerWidth: centerWidth)))
    }

    /// 中央が最小幅を保てるウィンドウの最小幅（ステージパネルは狭いと畳むので畳んだ幅で数える）。
    public static func minimumWindowWidth(listWidth: Double) -> Double {
        fixedChrome + clamped(listWidth) + centerMinimum
    }

    /// ウィンドウの幅で中央が最小幅を保てるよう縮めた幅。保存値は変えず、描く幅だけに使う。
    public static func fitted(_ preferred: Double, windowWidth: Double?) -> Double {
        let width = clamped(preferred)
        guard let windowWidth, windowWidth.isFinite else { return width }
        return max(minimum, min(width, windowWidth - fixedChrome - centerMinimum))
    }

    private static func upperBound(from base: Double, centerWidth: Double) -> Double {
        let slack = centerWidth.isFinite ? max(centerWidth - centerMinimum, 0) : 0
        return max(minimum, min(maximum, base + slack))
    }
}

/// 境界をつかんでいる間の幅。ステージパネルの開閉はつかんだ時の幅で判定し、離した時に反映する（途中で組み直さない）。
public struct ListPaneDrag: Equatable, Sendable {
    public let startWidth: Double
    public let startCenterWidth: Double
    public private(set) var width: Double

    public init(startWidth: Double, centerWidth: Double) {
        self.startWidth = ListPaneWidth.clamped(startWidth)
        self.startCenterWidth = centerWidth
        self.width = self.startWidth
    }

    public mutating func move(translation: Double) {
        width = ListPaneWidth.dragged(start: startWidth, translation: translation, centerWidth: startCenterWidth)
    }

    /// ステージパネルの自動で畳む判定に使う幅。
    public var widthForStage: Double { startWidth }
}
