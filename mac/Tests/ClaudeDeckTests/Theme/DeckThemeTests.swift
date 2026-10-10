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
                       [0x34d399, 0x053321, 0x053321, 0x141c2d, 0x0b111d])
        XCTAssertEqual([p.feedTool, p.feedPrompt, p.feedStatus, p.feedSession, p.feedAgent],
                       [0x7dd3fc, 0xc4b5fd, 0xfcd34d, 0x6ee7b7, 0xf0abfc])
        // 名前のハッシュで引く 8 色（blue → red の順）は、キーを足す前の色のまま。
        XCTAssertEqual(ProjectColor.hashCandidates.map(p.avatar),
                       [0x60a5fa, 0xa78bfa, 0xf472b6, 0xfb923c, 0xfacc15, 0x34d399, 0x22d3ee, 0xf87171])
        XCTAssertEqual([p.avatar(.indigo), p.avatar(.brown), p.avatar(.gray)], [0x818cf8, 0xd4a373, 0x9ca3af])
        XCTAssertEqual(DeckTheme.night.palette, .night)
        XCTAssertEqual([p.selectionInk, p.link], [p.accent, p.accent])
    }

    /// ライトのために足したトークンも、ナイトでは元の部品が使っていた色・濃さのまま。
    func testNightAddedTokensMatchOriginalLook() {
        let p = ThemePalette.night
        XCTAssertEqual(p.cardFill, .tint(p.permission, 0.06))
        XCTAssertEqual(p.cardBorder, .solid(p.permission))
        XCTAssertEqual(p.permissionChip, .tint(p.permission, 0.14))
        XCTAssertEqual(p.menuTabCurrent, .tint(p.permission, 0.25))
        XCTAssertEqual(p.permissionBadge, .tint(p.permission, 0.18))
        XCTAssertEqual(p.waitingBadge, .tint(p.waiting, 0.18))
        XCTAssertEqual(p.toolsFill, .solid(p.inputSurface))
        XCTAssertEqual(p.toolsBorder, .solid(p.border))
        XCTAssertEqual(p.toolsRunningFill, .tint(p.working, 0.1))
        XCTAssertEqual(p.toolsRunningBorder, .tint(p.working, 0.4))
        XCTAssertEqual(p.externalBanner, .tint(p.waiting, 0.07))
        XCTAssertEqual(p.relayFill, .tint(p.permission, 0.06))
        XCTAssertEqual(p.externalTagFill.opacity, 0)
        XCTAssertEqual(p.externalTagBorder, .solid(p.inputBorder))
        XCTAssertEqual(p.quietButton, .solid(p.inputSurface))
        XCTAssertEqual(p.quietButtonBorder, .solid(p.inputBorder))
    }

    func testNightStageBackdropKeepsOriginalColors() {
        let b = StageBackdrop.night
        XCTAssertEqual([b.ground, b.groundUnderHalo, b.grid, b.gridCenter, b.fog, b.stone, b.shade, b.cap],
                       [0x16243a, 0x0a1426, 0x142234, 0x1e3a5f, 0x070c14, 0xaeb9cc, 0x8b97ab, 0x0d1726])
        // 1 以下なら照り返しの強さは既定の 1 のままで、描画が変わらない。
        XCTAssertTrue(b.groundEmission == (0.0085, 0.0080, 0.0105))
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

    func testLightFillsAreOpaqueSoContrastIsMeasuredOnTheirOwn() {
        let p = ThemePalette.light
        let fills = [p.cardFill, p.pendingCardFill, p.cardBorder, p.permissionChip, p.menuTabCurrent, p.permissionBadge,
                     p.waitingBadge, p.toolsFill, p.toolsRunningFill, p.externalBanner, p.relayFill, p.quietButton]
        for fill in fills { XCTAssertEqual(fill.opacity, 1, "\(fill)") }
    }

    func testNightPendingCardKeepsOriginalLook() {
        XCTAssertEqual(ThemePalette.night.pendingCardFill, .tint(ThemePalette.night.permission, 0.04))
    }

    /// ライトの面（不透明の塗りを含む）。
    private var lightSurfaces: [UInt32] {
        let p = ThemePalette.light
        let fills = [p.cardFill, p.pendingCardFill, p.permissionChip, p.menuTabCurrent, p.permissionBadge, p.waitingBadge, p.toolsFill,
                     p.toolsRunningFill, p.externalBanner, p.relayFill, p.externalTagFill, p.quietButton]
        return [p.background, p.sidebar, p.claudeBubble, p.inputSurface, p.codeSurface, p.selectedRow,
                p.stagePanel, p.userBubble] + fills.map { $0.over(p.background) }
    }

    /// ライトの文字は、載るどの面の上でも本文 7 以上・補助 4.5 以上・状態色 4.5 以上。
    func testLightTextIsReadable() {
        let p = ThemePalette.light
        for surface in lightSurfaces {
            for (name, ink) in [("text", p.text), ("heading", p.heading), ("secondary", p.secondary)] {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, surface), 7, "\(name) on \(String(surface, radix: 16))")
            }
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.tertiary, surface), 4.5, "tertiary on \(String(surface, radix: 16))")
        }
        // 状態・フィード・アバター・リンクの色の文字が載る面。
        let inkSurfaces = [p.background, p.sidebar, p.claudeBubble, p.inputSurface, p.codeSurface,
                           p.selectedRow, p.stagePanel, p.cardFill.over(p.background)]
        let inks = [p.permission, p.waiting, p.working, p.idle, p.error, p.feedTool, p.feedPrompt, p.feedStatus,
                    p.feedSession, p.feedAgent, p.selectionInk, p.link] + p.avatarPalette
        for surface in inkSurfaces {
            for ink in inks {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, surface), 4.5,
                                            "\(String(ink, radix: 16)) on \(String(surface, radix: 16))")
            }
        }
        // バッジ・チップ・カードは、その地と載せる色の組で測る。
        let pairs: [(String, UInt32, ThemeFill)] = [
            ("ツール名", p.permission, p.permissionChip), ("権限待ちバッジ", p.permission, p.permissionBadge),
            ("入力待ちバッジ", p.waiting, p.waitingBadge), ("実行中のツール", p.working, p.toolsRunningFill),
            ("ツール", p.tertiary, p.toolsFill), ("外部タグ", p.secondary, p.externalTagFill),
            ("伝言", p.text, p.relayFill), ("引き継ぎの案内", p.waiting, p.externalBanner),
            ("拒否・キャンセル", p.text, p.quietButton), ("今のタブ", p.heading, p.menuTabCurrent),
            ("権限待ちの案内", p.permission, p.pendingCardFill),
        ]
        for (name, ink, fill) in pairs {
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, fill.over(p.background)), 4.5, name)
        }
        // 状態色を薄く塗った面（見出しのバッジ等）の上に同じ色の文字を載せる。
        for ink in [p.permission, p.waiting, p.working, p.error] + p.avatarPalette {
            let tint = ThemeContrast.blend(ink, over: p.background, opacity: 0.25)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, tint), 3.5, String(ink, radix: 16))
        }
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.userBubbleText, p.userBubble), 7)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.onAccent, p.accent), 7)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.onPermission, p.permission), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.background, p.permission), 4.5)
    }

    /// 面は白で、段差・区切りは色味の無いごく薄いグレーだけ。
    func testLightSurfacesAreWhiteWithQuietGrays() {
        let p = ThemePalette.light
        XCTAssertEqual([p.background, p.stagePanel, p.claudeBubble], [0xffffff, 0xffffff, 0xffffff])
        for step in [p.sidebar, p.inputSurface, p.codeSurface] {
            XCTAssertLessThanOrEqual(chroma(step), 8, String(step, radix: 16))
            XCTAssertGreaterThanOrEqual(ThemeContrast.lightness(step), 95, String(step, radix: 16))
            XCTAssertLessThan(ThemeContrast.lightness(step), 100, String(step, radix: 16))
        }
        for line in [p.border, p.inputBorder, p.claudeBubbleBorder] {
            XCTAssertLessThanOrEqual(chroma(line), 12, String(line, radix: 16))
            XCTAssertGreaterThanOrEqual(ThemeContrast.lightness(line), 85, String(line, radix: 16))
        }
        // 文字のグレーは色味を持たせない。
        for ink in [p.text, p.secondary, p.tertiary, p.heading, p.idle] {
            XCTAssertLessThanOrEqual(chroma(ink), 24, String(ink, radix: 16))
        }
    }

    /// 色は赤・青・緑・黄の 4 色相だけで、役割ごとに決まった色相を使う。
    func testLightUsesFourPastelHuesByRole() {
        let p = ThemePalette.light
        let roles: [(PastelHue, [UInt32])] = [
            (.blue, [p.selectedRow, p.selectionInk, p.link, p.waiting, p.userBubble, p.userBubbleText, p.waitingBadge.hex,
                     p.externalBanner.hex, p.externalTagFill.hex, p.externalTagBorder.hex, p.feedPrompt, p.feedAgent]),
            (.green, [p.working, p.accent, p.onAccent, p.toolsRunningFill.hex, p.toolsRunningBorder.hex, p.feedSession]),
            (.yellow, [p.permission, p.cardFill.hex, p.cardBorder.hex, p.pendingCardFill.hex, p.permissionChip.hex,
                       p.menuTabCurrent.hex, p.permissionBadge.hex, p.toolsFill.hex, p.toolsBorder.hex, p.relayFill.hex, p.feedTool]),
            (.red, [p.error, p.quietButton.hex, p.quietButtonBorder.hex, p.feedStatus]),
        ]
        for (hue, colors) in roles {
            for color in colors { XCTAssertEqual(PastelHue(color), hue, String(color, radix: 16)) }
        }
    }

    /// 印の色は利用者が選ぶ 11 色で、ライトはナイトと同じ色相の濃い版（灰だけは色味を持たない）。
    func testAvatarPaletteKeepsHueAcrossThemes() {
        XCTAssertEqual(ThemePalette.night.avatarPalette.count, ProjectColor.allCases.count)
        XCTAssertEqual(ThemePalette.light.avatarPalette.count, ProjectColor.allCases.count)
        for key in ProjectColor.allCases {
            let night = ThemePalette.night.avatar(key), light = ThemePalette.light.avatar(key)
            if key == .gray {
                XCTAssertLessThanOrEqual(chroma(night), 24)
                XCTAssertLessThanOrEqual(chroma(light), 24)
                continue
            }
            let (hn, hl) = (hue(night), hue(light))
            let distance = min(abs(hn - hl), 360 - abs(hn - hl))
            XCTAssertLessThanOrEqual(distance, 20, "\(key): night \(Int(hn))° light \(Int(hl))°")
            XCTAssertLessThan(ThemeContrast.lightness(light), ThemeContrast.lightness(night), "\(key)")
        }
        // 同じテーマの中で同じ色を 2 つのキーに使わない。
        XCTAssertEqual(Set(ThemePalette.night.avatarPalette).count, ProjectColor.allCases.count)
        XCTAssertEqual(Set(ThemePalette.light.avatarPalette).count, ProjectColor.allCases.count)
    }

    private func hue(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xff), g = Double((hex >> 8) & 0xff), b = Double(hex & 0xff)
        let (hi, lo) = (max(r, g, b), min(r, g, b))
        guard hi > lo else { return 0 }
        var hue: Double
        if hi == r { hue = 60 * ((g - b) / (hi - lo)) } else if hi == g { hue = 60 * ((b - r) / (hi - lo) + 2) } else { hue = 60 * ((r - g) / (hi - lo) + 4) }
        if hue < 0 { hue += 360 }
        return hue
    }

    func testLightStageBackdropBlendsWithPanel() {
        let b = StageBackdrop.light
        let panel = ThemePalette.light.stagePanel
        XCTAssertEqual(b.fog, panel)
        XCTAssertLessThan(abs(ThemeContrast.lightness(b.groundUnderHalo) - ThemeContrast.lightness(panel)), 5)
        for hex in [b.ground, b.groundUnderHalo, b.grid, b.gridCenter, b.stone, b.shade] {
            XCTAssertLessThanOrEqual(chroma(hex), 16, String(hex, radix: 16))
        }
    }

    private func chroma(_ hex: UInt32) -> UInt32 {
        let c = [(hex >> 16) & 0xff, (hex >> 8) & 0xff, hex & 0xff]
        return c.max()! - c.min()!
    }

    func testLightBadgeColorsReadOnWhiteAndTint() {
        let p = ThemePalette.light
        for key in ProjectColor.allCases {
            let ink = p.avatar(key)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, 0xffffff), 4.5, key.rawValue)
            let tint = ThemeContrast.blend(ink, over: 0xffffff, opacity: 0.14)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, tint), 3.0, key.rawValue)
        }
    }
}

/// ライトで使ってよい 4 つの色相（HSL の色相角の帯）。
private enum PastelHue: CaseIterable {
    case red, yellow, green, blue

    init?(_ hex: UInt32) {
        let r = Double((hex >> 16) & 0xff), g = Double((hex >> 8) & 0xff), b = Double(hex & 0xff)
        let (hi, lo) = (max(r, g, b), min(r, g, b))
        guard hi - lo >= 12 else { return nil }
        var hue: Double
        if hi == r { hue = 60 * ((g - b) / (hi - lo)) } else if hi == g { hue = 60 * ((b - r) / (hi - lo) + 2) } else { hue = 60 * ((r - g) / (hi - lo) + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case 345..., ..<15: self = .red
        case 35..<58: self = .yellow
        case 120..<165: self = .green
        case 200..<230: self = .blue
        default: return nil
        }
    }
}
