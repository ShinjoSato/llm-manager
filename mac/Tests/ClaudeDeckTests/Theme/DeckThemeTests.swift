import XCTest
@testable import MonitorKit

final class DeckThemeTests: XCTestCase {
    func testStoredValueFallsBackToNight() {
        XCTAssertEqual(DeckTheme(stored: nil), .night)
        XCTAssertEqual(DeckTheme(stored: ""), .night)
        XCTAssertEqual(DeckTheme(stored: "dark"), .night)
        XCTAssertEqual(DeckTheme(stored: "night"), .night)
        XCTAssertEqual(DeckTheme(stored: "light"), .light)
        XCTAssertEqual(DeckTheme.default, .night)
        XCTAssertEqual(DeckTheme.allCases.map(\.label), ["ナイト", "ライト"])
    }

    /// ナイトは切り替えを入れる前の配色のまま。
    func testNightKeepsOriginalColors() {
        let p = ThemePalette.night
        XCTAssertEqual([p.background, p.sidebar, p.border, p.inputSurface, p.inputBorder, p.selectedRow],
                       [0x0a0f1a, 0x0d1320, 0x1c2433, 0x121a29, 0x26324a, 0x1a2335])
        XCTAssertEqual([p.text, p.secondary, p.tertiary, p.heading], [0xe6ebf2, 0x97a3b6, 0x7c889b, 0xf1f5f9])
        XCTAssertEqual([p.permission, p.waiting, p.working, p.idle, p.error],
                       [0xfbbf24, 0x7cc4ff, 0x34d399, 0x97a3b6, 0xf87171])
        XCTAssertEqual([p.userBubble, p.userBubbleText, p.claudeBubble, p.claudeBubbleBorder],
                       [0x2563eb, 0xffffff, 0x172033, 0x222d42])
        XCTAssertEqual([p.accent, p.onAccent, p.onPermission, p.codeSurface, p.stagePanel],
                       [0x34d399, 0x053321, 0x053321, 0x0d1320, 0x0b111d])
        XCTAssertEqual([p.feedTool, p.feedPrompt, p.feedStatus, p.feedSession, p.feedAgent],
                       [0x7dd3fc, 0xc4b5fd, 0xfcd34d, 0x6ee7b7, 0xf0abfc])
        XCTAssertEqual(p.avatarPalette, [0x60a5fa, 0xa78bfa, 0xf472b6, 0xfb923c, 0xfacc15, 0x34d399, 0x22d3ee, 0xf87171])
        XCTAssertEqual(DeckTheme.night.palette, .night)
    }

    func testNightStageBackdropKeepsOriginalColors() {
        let b = StageBackdrop.night
        XCTAssertEqual([b.ground, b.groundUnderHalo, b.grid, b.gridCenter, b.fog, b.stone, b.shade, b.cap],
                       [0x16243a, 0x0a1426, 0x142234, 0x1e3a5f, 0x070c14, 0xaeb9cc, 0x8b97ab, 0x0d1726])
        XCTAssertEqual(StageBackdrop.for(.night), .night)
        XCTAssertEqual(StageBackdrop.for(.light), .light)
    }

    func testPalettesHaveSameAvatarCount() {
        XCTAssertEqual(ThemePalette.light.avatarPalette.count, ThemePalette.night.avatarPalette.count)
    }

    func testContrastRatio() {
        XCTAssertEqual(ThemeContrast.ratio(0x000000, 0xffffff), 21, accuracy: 0.01)
        XCTAssertEqual(ThemeContrast.ratio(0x777777, 0x777777), 1, accuracy: 1e-9)
        XCTAssertEqual(ThemeContrast.blend(0x000000, over: 0xffffff, opacity: 0.5), 0x808080)
    }

    /// ライトの文字は、載る面（背景・サイドバー・吹き出し・入力欄・薄い状態色の塗り）の上で読める濃さ。
    func testLightTextIsReadable() {
        let p = ThemePalette.light
        let surfaces = [p.background, p.sidebar, p.claudeBubble, p.inputSurface, p.codeSurface, p.selectedRow, p.stagePanel]
        for surface in surfaces {
            for (name, ink) in [("text", p.text), ("heading", p.heading), ("secondary", p.secondary)] {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, surface), 7, "\(name) on \(String(surface, radix: 16))")
            }
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.tertiary, surface), 4.5, "tertiary on \(String(surface, radix: 16))")
            let inks = [p.permission, p.waiting, p.working, p.idle, p.error, p.feedTool, p.feedPrompt, p.feedStatus,
                        p.feedSession, p.feedAgent] + p.avatarPalette
            for ink in inks {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, surface), 4.5,
                                            "\(String(ink, radix: 16)) on \(String(surface, radix: 16))")
            }
        }
        // 状態色を薄く塗った面（カード・バッジ・チップ）の上に同じ色の文字を載せる。
        for ink in [p.permission, p.waiting, p.working, p.error] + p.avatarPalette {
            let tint = ThemeContrast.blend(ink, over: p.background, opacity: 0.25)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, tint), 3.5, String(ink, radix: 16))
        }
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.userBubbleText, p.userBubble), 7)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.onAccent, p.accent), 7)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.onPermission, p.permission), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.background, p.permission), 4.5)
    }

    /// ライトの面はどれも白に近い（パステルの面と暗い文字の組み合わせになっている）。
    func testLightSurfacesAreBright() {
        let p = ThemePalette.light
        for surface in [p.background, p.sidebar, p.claudeBubble, p.inputSurface, p.codeSurface, p.stagePanel,
                        p.userBubble, p.accent, p.selectedRow] {
            XCTAssertGreaterThan(ThemeContrast.luminance(surface), 0.6, String(surface, radix: 16))
        }
    }
}
