import Foundation

/// ステージの背景側（地面・格子・霧・段）の色。キャラと持ち物の色はテーマで変えない。
public struct StageBackdrop: Sendable, Equatable {
    public var ground: UInt32
    /// 地面に足す一定の明るさ（線形）。lambert に無い照り返しの代わり。
    public var groundEmission: (r: Double, g: Double, b: Double)
    /// 光の輪の下に見える地面の色（sRGB）。比べ撮りで測った地面の色に合わせる。
    public var groundUnderHalo: UInt32
    public var grid: UInt32
    public var gridCenter: UInt32
    public var fog: UInt32
    public var stone: UInt32
    public var shade: UInt32
    public var cap: UInt32

    public static let night = StageBackdrop(
        ground: 0x16243a, groundEmission: (0.0085, 0.0080, 0.0105), groundUnderHalo: 0x0a1426,
        grid: 0x142234, gridCenter: 0x1e3a5f, fog: 0x070c14,
        stone: 0xaeb9cc, shade: 0x8b97ab, cap: 0x0d1726
    )

    // パネルの淡い藤色に床と霧を寄せ、照り返しでトーンマッピングに沈む分を持ち上げる。
    public static let light = StageBackdrop(
        ground: 0xeee0fa, groundEmission: (0.44, 0.33, 0.56), groundUnderHalo: 0xe3dde8,
        grid: 0xd5cde6, gridCenter: 0xb4a5dc, fog: 0xebe7f2,
        stone: 0xd3cde3, shade: 0xaea6c6, cap: 0x6a5f8c
    )

    public static func `for`(_ theme: DeckTheme) -> StageBackdrop {
        theme == .light ? .light : .night
    }

    public static func == (a: StageBackdrop, b: StageBackdrop) -> Bool {
        a.ground == b.ground && a.groundEmission == b.groundEmission && a.groundUnderHalo == b.groundUnderHalo
            && a.grid == b.grid && a.gridCenter == b.gridCenter && a.fog == b.fog && a.stone == b.stone
            && a.shade == b.shade && a.cap == b.cap
    }
}
