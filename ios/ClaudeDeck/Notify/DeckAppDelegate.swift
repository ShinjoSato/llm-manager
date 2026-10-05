import CloudKit
import DeckCore
import UIKit
import UserNotifications

/// 通知の受け口。開かれた通知は、画面のモデルが繋がるまで預かる。
@MainActor
final class DeckAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 通知を開いた時の行き先。
    var onOpen: ((AttentionNoticeRoute) -> Void)? {
        didSet {
            guard let onOpen, let pending = pendingRoute else { return }
            pendingRoute = nil
            onOpen(pending)
        }
    }

    /// アプリを開いている時に届いた知らせを出すか。
    var shouldPresent: ((AttentionNoticeRoute?) -> Bool)?
    private var pendingRoute: AttentionNoticeRoute?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // CloudKit が端末のトークンを受け取るので、アプリ側では何もしない。
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {}

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        MainActor.assumeIsolated {
            let route = Self.route(from: userInfo)
            let present = shouldPresent?(route) ?? true
            completionHandler(present ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        MainActor.assumeIsolated {
            if let route = Self.route(from: userInfo) {
                if let onOpen { onOpen(route) } else { pendingRoute = route }
            }
            completionHandler()
        }
    }

    static func route(from userInfo: [AnyHashable: Any]) -> AttentionNoticeRoute? {
        if let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
           let fields = query.recordFields, let route = AttentionNoticeRoute(fields: fields.mapValues { $0 as Any }) {
            return route
        }
        return AttentionNoticeRoute(userInfo: userInfo)
    }
}
