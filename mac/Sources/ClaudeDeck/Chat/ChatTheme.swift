import SwiftUI
import MonitorKit

/// 画面案B のトークン（ダーク固定）。
enum ChatTheme {
    static let background = Color(hex: 0x0a0f1a)
    static let sidebar = Color(hex: 0x0d1320)
    static let border = Color(hex: 0x1c2433)
    static let inputSurface = Color(hex: 0x121a29)
    static let inputBorder = Color(hex: 0x26324a)
    static let selectedRow = Color(hex: 0x1a2335)

    static let text = Color(hex: 0xe6ebf2)
    static let secondary = Color(hex: 0x97a3b6)
    static let tertiary = Color(hex: 0x7c889b)
    static let heading = Color(hex: 0xf1f5f9)

    static let permission = Color(hex: 0xfbbf24)
    static let waiting = Color(hex: 0x7cc4ff)
    static let working = Color(hex: 0x34d399)
    static let idle = Color(hex: 0x97a3b6)
    static let error = Color(hex: 0xf87171)

    static let userBubble = Color(hex: 0x2563eb)
    static let claudeBubble = Color(hex: 0x172033)
    static let claudeBubbleBorder = Color(hex: 0x222d42)
    static let accent = Color(hex: 0x34d399)
    static let onAccent = Color(hex: 0x053321)
    static let codeSurface = Color(hex: 0x0d1320)

    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)
    static let headline = Font.system(size: 16, weight: .bold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoBody = Font.system(size: 13, design: .monospaced)

    /// プロジェクトの頭文字アイコンの色（名前から決定的に選ぶ）。
    static let avatarPalette: [Color] = [
        Color(hex: 0x60a5fa), Color(hex: 0xa78bfa), Color(hex: 0xf472b6), Color(hex: 0xfb923c),
        Color(hex: 0xfacc15), Color(hex: 0x34d399), Color(hex: 0x22d3ee), Color(hex: 0xf87171),
    ]

    static func avatarColor(for name: String) -> Color {
        avatarPalette[RoomGrouping.colorIndex(for: name, paletteSize: avatarPalette.count)]
    }

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .permission: return permission
        case .waiting: return waiting
        case .working: return working
        case .error: return error
        case .stopped: return tertiary
        case .idle, .unknown: return idle
        }
    }

    static func label(for status: SessionStatus) -> String {
        switch status {
        case .permission: return "権限待ち"
        case .waiting: return "入力待ち"
        case .working: return "稼働中"
        case .idle: return "待機"
        case .error: return "エラー"
        case .stopped: return "終了"
        case .unknown: return "不明"
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

/// 時刻の短い表記（今日なら HH:mm、それ以外は M/d）。
enum ChatTime {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }

    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "たった今" }
        if seconds < 3600 { return "\(Int(seconds / 60))分前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))時間前" }
        return "\(Int(seconds / 86_400))日前"
    }
}
