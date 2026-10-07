import SwiftUI
import MonitorKit

/// チャット画面のトークン。色はテーマ（ナイト / ライト）ごとの値を持ち、描く時の外観で選ばれる。
enum ChatTheme {
    static let background = color(\.background)
    static let nsBackground = nsColor(\.background)
    static let sidebar = color(\.sidebar)
    static let border = color(\.border)
    static let inputSurface = color(\.inputSurface)
    static let inputBorder = color(\.inputBorder)
    static let selectedRow = color(\.selectedRow)
    static let selectionInk = color(\.selectionInk)
    static let link = color(\.link)

    static let text = color(\.text)
    static let nsText = nsColor(\.text)
    static let secondary = color(\.secondary)
    static let tertiary = color(\.tertiary)
    static let nsTertiary = nsColor(\.tertiary)
    static let heading = color(\.heading)

    static let permission = color(\.permission)
    static let waiting = color(\.waiting)
    static let working = color(\.working)
    static let idle = color(\.idle)
    static let error = color(\.error)

    static let userBubble = color(\.userBubble)
    static let userBubbleText = color(\.userBubbleText)
    static let claudeBubble = color(\.claudeBubble)
    static let claudeBubbleBorder = color(\.claudeBubbleBorder)
    static let accent = color(\.accent)
    static let onAccent = color(\.onAccent)
    /// 権限色の塗りの上に載せる文字・記号。
    static let onPermission = color(\.onPermission)
    static let codeSurface = color(\.codeSurface)
    static let stagePanel = color(\.stagePanel)

    /// ライブフィードの種類ごとの色。
    static let feedTool = color(\.feedTool)
    static let feedPrompt = color(\.feedPrompt)
    static let feedStatus = color(\.feedStatus)
    static let feedSession = color(\.feedSession)
    static let feedAgent = color(\.feedAgent)

    static let cardFill = fill(\.cardFill)
    static let cardBorder = fill(\.cardBorder)
    static let pendingCardFill = fill(\.pendingCardFill)
    static let permissionChip = fill(\.permissionChip)
    static let menuTabCurrent = fill(\.menuTabCurrent)
    static let toolsFill = fill(\.toolsFill)
    static let toolsBorder = fill(\.toolsBorder)
    static let toolsRunningFill = fill(\.toolsRunningFill)
    static let toolsRunningBorder = fill(\.toolsRunningBorder)
    static let externalBanner = fill(\.externalBanner)
    static let relayFill = fill(\.relayFill)
    static let externalTagFill = fill(\.externalTagFill)
    static let externalTagBorder = fill(\.externalTagBorder)
    static let quietButton = fill(\.quietButton)
    static let quietButtonBorder = fill(\.quietButtonBorder)
    private static let permissionBadge = fill(\.permissionBadge)
    private static let waitingBadge = fill(\.waitingBadge)

    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)
    static let headline = Font.system(size: 16, weight: .bold)
    static let mono = Font.system(size: 12, design: .monospaced)

    /// プロジェクトの印の色（`ProjectColor.allCases` の順。ナイト / ライトで動的）。
    static let avatarPalette: [Color] = ProjectColor.allCases.map { key in
        Color(nsColor: dynamic(night: ThemePalette.night.avatar(key), light: ThemePalette.light.avatar(key)))
    }

    // MARK: - テーマと外観

    /// テーマごとのウィンドウの外観。色はこの外観から引くので、切り替えは外観を差し替えるだけで全画面に届く。
    static func appearance(for theme: DeckTheme) -> NSAppearance? {
        NSAppearance(named: theme == .light ? .aqua : .darkAqua)
    }

    static func colorScheme(for theme: DeckTheme) -> ColorScheme {
        theme == .light ? .light : .dark
    }

    private static func color(_ key: KeyPath<ThemePalette, UInt32>) -> Color {
        Color(nsColor: nsColor(key))
    }

    private static func nsColor(_ key: KeyPath<ThemePalette, UInt32>) -> NSColor {
        dynamic(night: ThemePalette.night[keyPath: key], light: ThemePalette.light[keyPath: key])
    }

    private static func fill(_ key: KeyPath<ThemePalette, ThemeFill>) -> Color {
        let night = ThemePalette.night[keyPath: key]
        let light = ThemePalette.light[keyPath: key]
        return Color(nsColor: dynamic(NSColor(hex: night.hex).withAlphaComponent(night.opacity),
                                      NSColor(hex: light.hex).withAlphaComponent(light.opacity)))
    }

    private static func dynamic(night: UInt32, light: UInt32) -> NSColor {
        dynamic(NSColor(hex: night), NSColor(hex: light))
    }

    private static func dynamic(_ nightColor: NSColor, _ lightColor: NSColor) -> NSColor {
        return NSColor(name: nil) { appearance in
            // ポップオーバー等の vibrant 系も明暗で振り分ける。
            switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
            case .aqua?, .vibrantLight?: return lightColor
            default: return nightColor
            }
        }
    }

    static func avatarColor(for key: ProjectColor) -> Color {
        avatarPalette[key.paletteIndex]
    }

    /// 名前から決める既定の色（設定で色を選んでいないプロジェクト）。
    static func avatarColor(for name: String) -> Color {
        avatarColor(for: ProjectBadge.defaultColor(for: name))
    }

    /// 要対応のバッジの地。要対応でない状態は塗らない。
    static func attentionBadge(for status: SessionStatus) -> Color {
        switch status {
        case .permission: return permissionBadge
        case .waiting: return waitingBadge
        case .working, .idle, .error, .stopped, .unknown: return .clear
        }
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
    private static let timeFormatter = makeFormatter("HH:mm")
    private static let dayFormatter = makeFormatter("M/d")
    private static let secondsFormatter = makeFormatter("HH:mm:ss")
    private static let dayTimeFormatter = makeFormatter("M/d HH:mm")
    private static let stampFormatter = makeFormatter("yyyyMMdd-HHmmss")

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

    /// 「12:34:56」。
    static func seconds(_ date: Date) -> String { secondsFormatter.string(from: date) }
    /// 「6/4 12:34」。
    static func dayTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }
    /// ファイル名用の「20260604-123456」。
    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
}
