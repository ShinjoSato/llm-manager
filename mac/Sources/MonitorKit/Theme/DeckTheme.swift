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
        case .light: return "白い背景に、パステルの赤・青・緑・黄を添えた配色です。"
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

    public static let night = ThemePalette(
        background: 0x0a0f1a, sidebar: 0x0d1320, border: 0x1c2433, inputSurface: 0x121a29, inputBorder: 0x26324a,
        selectedRow: 0x1a2335,
        text: 0xe6ebf2, secondary: 0x97a3b6, tertiary: 0x7c889b, heading: 0xf1f5f9,
        permission: 0xfbbf24, waiting: 0x7cc4ff, working: 0x34d399, idle: 0x97a3b6, error: 0xf87171,
        userBubble: 0x2563eb, userBubbleText: 0xffffff, claudeBubble: 0x172033, claudeBubbleBorder: 0x222d42,
        accent: 0x34d399, onAccent: 0x053321, onPermission: 0x053321, codeSurface: 0x0d1320, stagePanel: 0x0b111d,
        feedTool: 0x7dd3fc, feedPrompt: 0xc4b5fd, feedStatus: 0xfcd34d, feedSession: 0x6ee7b7, feedAgent: 0xf0abfc,
        avatarPalette: [0x60a5fa, 0xa78bfa, 0xf472b6, 0xfb923c, 0xfacc15, 0x34d399, 0x22d3ee, 0xf87171]
    )

    // 文字にも使う状態色は白の上で読める濃さにし、薄く重ねた塗りでパステルに見せる。面の色（吹き出し・アクセント）はパステルに濃い文字を載せる。
    public static let light = ThemePalette(
        background: 0xffffff, sidebar: 0xf6f7fb, border: 0xe3e7ef, inputSurface: 0xf3f5f9, inputBorder: 0xd3dae6,
        selectedRow: 0xe4eefd,
        text: 0x1f2937, secondary: 0x434b58, tertiary: 0x5f6775, heading: 0x111827,
        permission: 0x945700, waiting: 0x1d64c8, working: 0x0f7a55, idle: 0x5b6472, error: 0xc0392b,
        userBubble: 0xd3e5ff, userBubbleText: 0x15315c, claudeBubble: 0xf5f7fb, claudeBubbleBorder: 0xe0e5ee,
        accent: 0xa6e9c4, onAccent: 0x0b4a2c, onPermission: 0xffffff, codeSurface: 0xf3f5f9, stagePanel: 0xf4f7fb,
        feedTool: 0x0e6aa8, feedPrompt: 0x6b3fc4, feedStatus: 0x945700, feedSession: 0x0f7a55, feedAgent: 0xa0329a,
        avatarPalette: [0x1d5bd6, 0x7c3aed, 0xc0267a, 0xb23c0a, 0x945700, 0x0f7a55, 0x0e7490, 0xc0392b]
    )
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
