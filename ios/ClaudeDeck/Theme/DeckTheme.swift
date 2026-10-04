import DeckCore
import SwiftUI

/// 画面のトークン（mac アプリのチャット画面と同じダーク固定の配色）。
enum DeckTheme {
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

    // iPhone は指で読む距離が近いので、mac より 1〜2pt 大きくする。
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 12.5)
    static let headline = Font.system(size: 17, weight: .bold)
    static let mono = Font.system(size: 12.5, design: .monospaced)

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

    static func title(for phase: RemoteRoomPhase) -> String {
        switch phase {
        case .attention: return "要対応"
        case .active: return "稼働中"
        case .idle, .unknown: return "待機"
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

/// 時刻の短い表記（今日なら HH:mm、それ以外は M/d）。
enum DeckTime {
    private static let timeFormatter = makeFormatter("HH:mm")
    private static let dayFormatter = makeFormatter("M/d")
    private static let dayTimeFormatter = makeFormatter("M/d HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = format
        return formatter
    }

    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let formatter = Calendar.current.isDate(date, inSameDayAs: now) ? timeFormatter : dayFormatter
        return formatter.string(from: date)
    }

    static func dayTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }
}
