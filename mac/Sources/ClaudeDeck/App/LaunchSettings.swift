import Foundation
import Observation

/// 起動時の再開の設定。UserDefaults に持ち、既定はどちらもオン。
@MainActor
@Observable
final class LaunchSettings {
    static let shared = LaunchSettings()

    private static let resumeKey = "launch.resumeHostedSessions"
    private static let continueKey = "launch.askToContinue"

    @ObservationIgnored private let defaults: UserDefaults

    /// 起動時に前回のセッションを再開する。
    var resumeOnLaunch: Bool {
        didSet { defaults.set(resumeOnLaunch, forKey: Self.resumeKey) }
    }

    /// 作業中だったものに続きを頼む。
    var askToContinue: Bool {
        didSet { defaults.set(askToContinue, forKey: Self.continueKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.resumeKey: true, Self.continueKey: true])
        resumeOnLaunch = defaults.bool(forKey: Self.resumeKey)
        askToContinue = defaults.bool(forKey: Self.continueKey)
    }
}
