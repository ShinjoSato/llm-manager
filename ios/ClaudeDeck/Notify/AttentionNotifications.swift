import CloudKit
import DeckCore
import Foundation
import Observation
import UIKit
import UserNotifications

/// iCloud の購読（mac が要対応を書いたらプッシュが届く）。試験では偽物に差し替える。
protocol AttentionSubscriptionService: Sendable {
    /// このビルドで iCloud の購読を使えない理由（署名にエンタイトルメントが無い等）。使えれば nil。
    func unavailableReason() -> String?
    /// iCloud を使えない理由。使えれば nil。
    func accountProblem() async -> String?
    func subscribe() async throws
    func unsubscribe() async throws
}

/// 通知の許可。
protocol NotificationAuthorizing: Sendable {
    func requestAuthorization() async throws -> Bool
    func isDenied() async -> Bool
}

/// 要対応の通知の入り切りと状態。入り切りは iCloud の購読を作る・消すことで行う（切っている間はプッシュ自体が来ない）。
@MainActor
@Observable
final class AttentionNotifications {
    enum State: Equatable {
        case off
        case working
        case on
        /// 入れたいが届かない（許可が無い・iCloud にサインインしていない・購読を作れない）。
        case problem(String, needsSettings: Bool)
    }

    private(set) var enabled: Bool
    private(set) var state: State
    /// このビルドでは使えない理由。あれば入れられない（設定は残し、使えるビルドで戻す）。
    let unavailableReason: String?

    private let service: AttentionSubscriptionService
    private let authorizer: NotificationAuthorizing
    private let defaults: UserDefaults
    private let registerForPush: @MainActor () -> Void
    static let enabledKey = "attentionNotifications.enabled"

    init(service: AttentionSubscriptionService, authorizer: NotificationAuthorizing, defaults: UserDefaults = .standard,
         registerForPush: @escaping @MainActor () -> Void) {
        self.service = service
        self.authorizer = authorizer
        self.defaults = defaults
        self.registerForPush = registerForPush
        let reason = service.unavailableReason()
        unavailableReason = reason
        let on = reason == nil && defaults.bool(forKey: Self.enabledKey)
        enabled = on
        if let reason, defaults.bool(forKey: Self.enabledKey) {
            state = .problem(reason, needsSettings: false)
        } else {
            state = on ? .working : .off
        }
    }

    static func live() -> AttentionNotifications {
        AttentionNotifications(service: CloudKitAttentionSubscription(), authorizer: SystemNotificationAuthorizer()) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func setEnabled(_ on: Bool) async {
        if let unavailableReason {
            enabled = false
            state = on ? .problem(unavailableReason, needsSettings: false) : .off
            return
        }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            await turnOn(asking: true)
        } else {
            state = .working
            do {
                try await service.unsubscribe()
                if !enabled { state = .off }
            } catch {
                guard !enabled else { return }
                state = .problem("iCloud の購読を消せませんでした（\(Self.describe(error))）。通知が届き続ける場合はもう一度切ってください。",
                                 needsSettings: false)
            }
        }
    }

    /// 起動・前に出た時。入れていれば購読を作り直す（消えていても戻す・同じ ID なので重複しない）。
    func refresh() async {
        guard enabled else { return }
        await turnOn(asking: false)
    }

    private func turnOn(asking: Bool) async {
        state = .working
        let granted: Bool
        if asking {
            granted = (try? await authorizer.requestAuthorization()) ?? false
        } else {
            granted = !(await authorizer.isDenied())
        }
        guard enabled else { return }
        guard granted else {
            state = .problem("通知が許可されていません。設定アプリで claude-deck の通知を許可してください。", needsSettings: true)
            return
        }
        if let problem = await service.accountProblem() {
            guard enabled else { return }
            state = .problem(problem, needsSettings: false)
            return
        }
        registerForPush()
        do {
            try await service.subscribe()
            if enabled { state = .on }
        } catch {
            guard enabled else { return }
            state = .problem("iCloud の購読を作れませんでした（\(Self.describe(error))）。Mac で一度要対応が書かれた後にもう一度入れてください。",
                             needsSettings: false)
        }
    }

    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError { return "CloudKit \(ck.code.rawValue)" }
        return error.localizedDescription
    }
}

/// 自分の iCloud のプライベート DB に、要対応の知らせが作られたらプッシュする購読を置く。
final class CloudKitAttentionSubscription: AttentionSubscriptionService, @unchecked Sendable {
    static let missingEntitlementReason =
        "このビルドには iCloud（CloudKit）とプッシュ通知のエンタイトルメントが無いため、通知を使えません。"
        + "iCloud を有効にした App ID とプロファイルで署名したビルドで使えます。"

    // CKContainer は作った時点でエンタイトルメントを確かめる（無ければ落ちる）ので、確かめてから使う時まで作らない。
    private lazy var container = CKContainer(identifier: AttentionNoticeSchema.containerIdentifier)
    private let lock = NSLock()
    private let entitled: Bool

    init(entitlements: [String: Any]? = ExecutableEntitlements.ofMainExecutable()) {
        entitled = AttentionNoticeSchema.entitlementsAllowNotices(entitlements, needsPush: true)
    }

    func unavailableReason() -> String? {
        entitled ? nil : Self.missingEntitlementReason
    }

    private func ckContainer() throws -> CKContainer {
        guard entitled else { throw CKError(.missingEntitlement) }
        return lock.withLock { container }
    }

    private func database() throws -> CKDatabase {
        try ckContainer().privateCloudDatabase
    }

    func accountProblem() async -> String? {
        guard entitled else { return Self.missingEntitlementReason }
        let status = try? await ckContainer().accountStatus()
        switch status {
        case .available: return nil
        case .noAccount: return "この iPhone で iCloud にサインインしていません。Mac と同じ Apple アカウントでサインインしてください。"
        case .restricted: return "iCloud の利用が制限されています。"
        case .temporarilyUnavailable: return "iCloud を一時的に使えません。しばらくしてからもう一度入れてください。"
        default: return "iCloud の状態を確かめられませんでした。"
        }
    }

    func subscribe() async throws {
        _ = try await database().modifySubscriptions(saving: [Self.makeSubscription()], deleting: [])
    }

    func unsubscribe() async throws {
        // 使えないビルドでは購読を作れていないので、消すものも無い。
        guard entitled else { return }
        do {
            _ = try await database().deleteSubscription(withID: AttentionNoticeSchema.subscriptionID)
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    /// 作成だけで知らせる（mac が知らせをまとめて書き直した時に鳴らさない）。見出しと本文はレコードの値をそのまま出す。
    static func makeSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: AttentionNoticeSchema.recordType, predicate: NSPredicate(value: true),
                                               subscriptionID: AttentionNoticeSchema.subscriptionID, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = AttentionNoticeSchema.titleLocalizationKey
        info.titleLocalizationArgs = [AttentionNoticeSchema.Field.title]
        info.alertLocalizationKey = AttentionNoticeSchema.bodyLocalizationKey
        info.alertLocalizationArgs = [AttentionNoticeSchema.Field.body]
        info.soundName = "default"
        info.desiredKeys = AttentionNoticeSchema.desiredKeys
        info.collapseIDKey = AttentionNoticeSchema.collapseIDKey
        info.category = AttentionNoticeSchema.notificationCategory
        subscription.notificationInfo = info
        return subscription
    }
}

struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}
