import AppKit
import MonitorKit
import Observation

/// 選んだカラーテーマ。UserDefaults に持ち、アプリ全体の外観に映す。
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var theme: DeckTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: DeckTheme.defaultsKey)
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = DeckTheme(stored: defaults.string(forKey: DeckTheme.defaultsKey))
    }

    /// 全ウィンドウ（チャット・設定・確認ダイアログ）の外観を揃える。色はこの外観から引かれる。
    func apply() {
        NSApp.appearance = ChatTheme.appearance(for: theme)
    }
}
