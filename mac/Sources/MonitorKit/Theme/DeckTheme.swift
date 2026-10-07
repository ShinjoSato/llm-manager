import Foundation

/// mac アプリのカラーテーマ。システムの外観には追従せず、設定で選んだものを使う。
public enum DeckTheme: String, CaseIterable, Sendable, Identifiable {
    case night
    case light

    /// UserDefaults の鍵。
    public static let defaultsKey = "appearance.theme"
    public static let `default`: DeckTheme = .night

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .night: return "ナイト"
        case .light: return "ライト"
        }
    }

    public var summary: String {
        switch self {
        case .night: return "暗い背景の配色です。"
        case .light: return "白の面に、パステルの赤・青・緑・黄を要所にだけ添えた配色です。"
        }
    }

    /// 保存値から読む。無い・知らない値は既定に戻す。
    public init(stored: String?) {
        self = stored.flatMap(DeckTheme.init(rawValue:)) ?? .default
    }

    public var palette: ThemePalette {
        switch self {
        case .night: return .night
        case .light: return .light
        }
    }
}

/// テーマごとの色（sRGB の 16 進）。画面の部品はこの名前で色を引く。
public struct ThemePalette: Sendable, Equatable {
    public var background: UInt32
    public var sidebar: UInt32
    public var border: UInt32
    public var inputSurface: UInt32
    public var inputBorder: UInt32
    public var selectedRow: UInt32
    /// 切り替えバーで選んでいる見方のアイコン。
    public var selectionInk: UInt32
    /// リンクの印。
    public var link: UInt32

    public var text: UInt32
    public var secondary: UInt32
    public var tertiary: UInt32
    public var heading: UInt32

    public var permission: UInt32
    public var waiting: UInt32
    public var working: UInt32
    public var idle: UInt32
    public var error: UInt32

    public var userBubble: UInt32
    public var userBubbleText: UInt32
    public var claudeBubble: UInt32
    public var claudeBubbleBorder: UInt32
    public var accent: UInt32
    public var onAccent: UInt32
    public var onPermission: UInt32
    public var codeSurface: UInt32
    public var stagePanel: UInt32

    public var feedTool: UInt32
    public var feedPrompt: UInt32
    public var feedStatus: UInt32
    public var feedSession: UInt32
    public var feedAgent: UInt32

    /// プロジェクトの印の色（`ProjectColor.allCases` の順。`avatar(_:)` でキーから引く）。
    public var avatarPalette: [UInt32]

    public func avatar(_ key: ProjectColor) -> UInt32 { avatarPalette[key.paletteIndex] }

    public var cardFill: ThemeFill
    public var cardBorder: ThemeFill
    /// 外部セッションの権限待ちの案内カードの地（答えられないので通常のカードより控えめ）。
    public var pendingCardFill: ThemeFill
    /// 権限カードのツール名の地。
    public var permissionChip: ThemeFill
    /// 選択肢カードの今の問いのタブ。
    public var menuTabCurrent: ThemeFill
    /// ディレクトリの行の要対応バッジ（権限待ち・入力待ち）。
    public var permissionBadge: ThemeFill
    public var waitingBadge: ThemeFill
    /// 「ツール N件」の地と縁（実行中は稼働の色）。
    public var toolsFill: ThemeFill
    public var toolsBorder: ThemeFill
    public var toolsRunningFill: ThemeFill
    public var toolsRunningBorder: ThemeFill
    public var externalBanner: ThemeFill
    public var relayFill: ThemeFill
    public var externalTagFill: ThemeFill
    public var externalTagBorder: ThemeFill
    /// 拒否・キャンセルなど控えめなボタン。
    public var quietButton: ThemeFill
    public var quietButtonBorder: ThemeFill

    public static let night = ThemePalette(
        background: 0x0a0f1a, sidebar: 0x0d1320, border: 0x1c2433, inputSurface: 0x121a29, inputBorder: 0x26324a,
        selectedRow: 0x1a2335, selectionInk: 0x34d399, link: 0x34d399,
        text: 0xe6ebf2, secondary: 0x97a3b6, tertiary: 0x7c889b, heading: 0xf1f5f9,
        permission: 0xfbbf24, waiting: 0x7cc4ff, working: 0x34d399, idle: 0x97a3b6, error: 0xf87171,
        userBubble: 0x2563eb, userBubbleText: 0xffffff, claudeBubble: 0x172033, claudeBubbleBorder: 0x222d42,
        accent: 0x34d399, onAccent: 0x053321, onPermission: 0x053321, codeSurface: 0x0d1320, stagePanel: 0x0b111d,
        feedTool: 0x7dd3fc, feedPrompt: 0xc4b5fd, feedStatus: 0xfcd34d, feedSession: 0x6ee7b7, feedAgent: 0xf0abfc,
        avatarPalette: [0xf87171, 0xfb923c, 0xfacc15, 0x34d399, 0x22d3ee, 0x60a5fa, 0x818cf8, 0xa78bfa, 0xf472b6, 0xd4a373, 0x9ca3af],
        cardFill: .tint(0xfbbf24, 0.06), cardBorder: .solid(0xfbbf24), pendingCardFill: .tint(0xfbbf24, 0.04),
        permissionChip: .tint(0xfbbf24, 0.14), menuTabCurrent: .tint(0xfbbf24, 0.25),
        permissionBadge: .tint(0xfbbf24, 0.18), waitingBadge: .tint(0x7cc4ff, 0.18),
        toolsFill: .solid(0x121a29), toolsBorder: .solid(0x1c2433),
        toolsRunningFill: .tint(0x34d399, 0.1), toolsRunningBorder: .tint(0x34d399, 0.4),
        externalBanner: .tint(0x7cc4ff, 0.07), relayFill: .tint(0xfbbf24, 0.06),
        externalTagFill: .clear, externalTagBorder: .solid(0x26324a),
        quietButton: .solid(0x121a29), quietButtonBorder: .solid(0x26324a)
    )

    // 面は白で、段差はごく薄いグレーだけ。色はパステルの赤・青・緑・黄の 4 色を役割で使い分け、文字はその濃い版で読める濃さにする。
    public static let light = ThemePalette(
        background: 0xffffff, sidebar: 0xf7f8fa, border: 0xe4e7ec, inputSurface: 0xf7f8fa, inputBorder: 0xd8dce3,
        selectedRow: 0xe3edfc, selectionInk: 0x1d5dbd, link: 0x1d5dbd,
        text: 0x1f2937, secondary: 0x3b424e, tertiary: 0x58606d, heading: 0x111827,
        permission: 0x7a5600, waiting: 0x1d5dbd, working: 0x1b6b3a, idle: 0x5b6370, error: 0xb02a22,
        userBubble: 0xdde9fc, userBubbleText: 0x15315c, claudeBubble: 0xffffff, claudeBubbleBorder: 0xe1e4ea,
        accent: 0xb4e6c6, onAccent: 0x0b4a2c, onPermission: 0xffffff, codeSurface: 0xf3f4f6, stagePanel: 0xffffff,
        feedTool: 0x7a5600, feedPrompt: 0x1d5dbd, feedStatus: 0xb02a22, feedSession: 0x1b6b3a, feedAgent: 0x2a4a8c,
        // 印の色だけは利用者が選ぶ 11 色相で、ナイトと同じ色相の濃い版（白い面の上で 4.5 以上）。
        avatarPalette: [0xb02a22, 0xa3480c, 0x7a5600, 0x1b6b3a, 0x0e6b6b, 0x1d5dbd, 0x4140b5, 0x6d3db4, 0xb02a74, 0x74482a, 0x5a6472],
        cardFill: .solid(0xfff5d4), cardBorder: .solid(0xecd07a), pendingCardFill: .solid(0xfff9e6),
        permissionChip: .solid(0xfbe7a6), menuTabCurrent: .solid(0xf8e08f),
        permissionBadge: .solid(0xfdedb3), waitingBadge: .solid(0xdde9fc),
        toolsFill: .solid(0xfff9e8), toolsBorder: .solid(0xf1e3b3),
        toolsRunningFill: .solid(0xdcf2e3), toolsRunningBorder: .solid(0xa8dbb8),
        externalBanner: .solid(0xe6effd), relayFill: .solid(0xfff5d4),
        externalTagFill: .solid(0xe6effd), externalTagBorder: .solid(0xbcd1f3),
        quietButton: .solid(0xfde3e0), quietButtonBorder: .solid(0xf1bdb6)
    )
}

/// 不透明度つきの塗り。ナイトは状態色を薄く重ね、ライトはパステルの面を不透明で塗る。
public struct ThemeFill: Sendable, Equatable {
    public var hex: UInt32
    public var opacity: Double

    public init(hex: UInt32, opacity: Double) {
        self.hex = hex
        self.opacity = opacity
    }

    public static func solid(_ hex: UInt32) -> ThemeFill { ThemeFill(hex: hex, opacity: 1) }
    public static func tint(_ hex: UInt32, _ opacity: Double) -> ThemeFill { ThemeFill(hex: hex, opacity: opacity) }
    public static let clear = ThemeFill(hex: 0, opacity: 0)

    /// 下の面に重ねた見た目の色。
    public func over(_ background: UInt32) -> UInt32 {
        ThemeContrast.blend(hex, over: background, opacity: opacity)
    }
}

/// WCAG の相対輝度とコントラスト比（文字の読みやすさを数値で確かめるため）。
public enum ThemeContrast {
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xff) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// CIE L*（0〜100）。面の明るさをそろえるために測る。
    public static func lightness(_ hex: UInt32) -> Double {
        let y = luminance(hex)
        return y > 216.0 / 24389.0 ? 116 * cbrt(y) - 16 : y * 24389.0 / 27.0
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 前景を不透明度 `opacity` で背景に重ねた色（薄い塗りの上の文字を測るため）。
    public static func blend(_ foreground: UInt32, over background: UInt32, opacity: Double) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let f = Double((foreground >> shift) & 0xff)
            let b = Double((background >> shift) & 0xff)
            return UInt32((f * opacity + b * (1 - opacity)).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }
}
