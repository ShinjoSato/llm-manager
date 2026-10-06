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
        case .light: return "生成りと淡い青の明るい面に、パステルの赤・青・緑・黄を添えた配色です。"
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

    public var avatarPalette: [UInt32]

    /// ルーム一覧の枠の地。
    public var sectionSurface: UInt32
    /// 枠の見出しの帯（アバター色と同じ並び）。
    public var sectionBands: [UInt32]

    public var cardFill: ThemeFill
    public var cardBorder: ThemeFill
    /// 外部セッションの権限待ちの案内カードの地（答えられないので通常のカードより控えめ）。
    public var pendingCardFill: ThemeFill
    /// 権限カードのツール名の地。
    public var permissionChip: ThemeFill
    /// 選択肢カードの今の問いのタブ。
    public var menuTabCurrent: ThemeFill
    /// 枠の見出しの要対応バッジ（権限待ち・入力待ち）。
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
        selectedRow: 0x1a2335,
        text: 0xe6ebf2, secondary: 0x97a3b6, tertiary: 0x7c889b, heading: 0xf1f5f9,
        permission: 0xfbbf24, waiting: 0x7cc4ff, working: 0x34d399, idle: 0x97a3b6, error: 0xf87171,
        userBubble: 0x2563eb, userBubbleText: 0xffffff, claudeBubble: 0x172033, claudeBubbleBorder: 0x222d42,
        accent: 0x34d399, onAccent: 0x053321, onPermission: 0x053321, codeSurface: 0x0d1320, stagePanel: 0x0b111d,
        feedTool: 0x7dd3fc, feedPrompt: 0xc4b5fd, feedStatus: 0xfcd34d, feedSession: 0x6ee7b7, feedAgent: 0xf0abfc,
        avatarPalette: [0x60a5fa, 0xa78bfa, 0xf472b6, 0xfb923c, 0xfacc15, 0x34d399, 0x22d3ee, 0xf87171],
        sectionSurface: 0x0a0f1a, sectionBands: Array(repeating: 0x0a0f1a, count: 8),
        cardFill: .tint(0xfbbf24, 0.06), cardBorder: .solid(0xfbbf24), pendingCardFill: .tint(0xfbbf24, 0.04),
        permissionChip: .tint(0xfbbf24, 0.14), menuTabCurrent: .tint(0xfbbf24, 0.25),
        permissionBadge: .tint(0xfbbf24, 0.18), waitingBadge: .tint(0x7cc4ff, 0.18),
        toolsFill: .solid(0x121a29), toolsBorder: .solid(0x1c2433),
        toolsRunningFill: .tint(0x34d399, 0.1), toolsRunningBorder: .tint(0x34d399, 0.4),
        externalBanner: .tint(0x7cc4ff, 0.07), relayFill: .tint(0xfbbf24, 0.06),
        externalTagFill: .clear, externalTagBorder: .solid(0x26324a),
        quietButton: .solid(0x121a29), quietButtonBorder: .solid(0x26324a)
    )

    // 面は純白を避けて L* 90〜96 の色味のあるトーンにし、段の差で区切る。文字に使う色はその上で読める濃さに沈める。
    public static let light = ThemePalette(
        background: 0xf1eee7, sidebar: 0xe4eaf3, border: 0xd3d6dd, inputSurface: 0xf6f3ec, inputBorder: 0xc8cfdb,
        selectedRow: 0xd2e1f7,
        text: 0x1f2937, secondary: 0x3b424e, tertiary: 0x58606d, heading: 0x111827,
        permission: 0x8a5100, waiting: 0x1b5dbb, working: 0x0d6c4c, idle: 0x58606e, error: 0xad3327,
        userBubble: 0xd4e3fa, userBubbleText: 0x15315c, claudeBubble: 0xfaf1d9, claudeBubbleBorder: 0xeadcb4,
        accent: 0xa6e9c4, onAccent: 0x0b4a2c, onPermission: 0xffffff, codeSurface: 0xebe7de, stagePanel: 0xebe7f2,
        feedTool: 0x0d639c, feedPrompt: 0x6b3fc4, feedStatus: 0x8a5100, feedSession: 0x0d6c4c, feedAgent: 0x9c3196,
        avatarPalette: [0x1c57cd, 0x732cec, 0xaf236f, 0xa83909, 0x8a5100, 0x0d6c4c, 0x0c6780, 0xad3327],
        sectionSurface: 0xedf1f7,
        sectionBands: [0xdce6fa, 0xe7defa, 0xf8dcea, 0xfbe3d2, 0xf8edc6, 0xd6f0e2, 0xd3eef2, 0xf8dad7],
        cardFill: .solid(0xfbefc9), cardBorder: .solid(0xe2b84f), pendingCardFill: .solid(0xfbefc9),
        permissionChip: .solid(0xf6dd99), menuTabCurrent: .solid(0xf3d888),
        permissionBadge: .solid(0xf9e2a6), waitingBadge: .solid(0xd6e4fb),
        toolsFill: .solid(0xe9e3f5), toolsBorder: .solid(0xd6cdee),
        toolsRunningFill: .solid(0xd5f0e1), toolsRunningBorder: .solid(0x9fd8b8),
        externalBanner: .solid(0xdde9f8), relayFill: .solid(0xfbefc9),
        externalTagFill: .solid(0xe6defa), externalTagBorder: .solid(0xc9b9ef),
        quietButton: .solid(0xf7dfdc), quietButtonBorder: .solid(0xe6bcb6)
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
