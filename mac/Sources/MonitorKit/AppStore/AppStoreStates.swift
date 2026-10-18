import Foundation

/// 状態の色分け（画面の印の色に使う）。
public enum AppStoreStateTone: Equatable, Sendable {
    case editing, waiting, inReview, rejected, pendingRelease, live, inactive, unknown
}

/// 版・アプリの情報・審査の提出の状態を日本語にする。知らない値は原文のまま出す。
public enum AppStoreStates {
    /// 版（appVersionState / appStoreState）とアプリの情報（state / appStoreState）の値。
    static let versionLabels: [String: String] = [
        "PREPARE_FOR_SUBMISSION": "提出準備中",
        "READY_FOR_REVIEW": "審査の提出待ち",
        "WAITING_FOR_REVIEW": "審査待ち",
        "IN_REVIEW": "審査中",
        "REJECTED": "リジェクト",
        "METADATA_REJECTED": "メタデータのリジェクト",
        "INVALID_BINARY": "バイナリが無効",
        "DEVELOPER_REJECTED": "取り下げ（開発者）",
        "PENDING_DEVELOPER_RELEASE": "公開待ち（手動で公開）",
        "PENDING_APPLE_RELEASE": "公開待ち（Apple の処理）",
        "PENDING_RELEASE": "公開待ち",
        "PENDING_CONTRACT": "契約の手続き待ち",
        "WAITING_FOR_EXPORT_COMPLIANCE": "輸出コンプライアンスの確認待ち",
        "PROCESSING_FOR_APP_STORE": "配信の準備中",
        "PROCESSING_FOR_DISTRIBUTION": "配信の準備中",
        "ACCEPTED": "承認済み",
        "READY_FOR_SALE": "公開中",
        "READY_FOR_DISTRIBUTION": "公開中",
        "PREORDER_READY_FOR_SALE": "予約注文の受付中",
        "REMOVED_FROM_SALE": "販売停止",
        "DEVELOPER_REMOVED_FROM_SALE": "販売停止（開発者）",
        "REPLACED_WITH_NEW_VERSION": "新しい版に置き換え済み",
        "REPLACED_WITH_NEW_INFO": "新しい情報に置き換え済み",
        "NOT_APPLICABLE": "該当なし",
    ]

    static let submissionLabels: [String: String] = [
        "READY_FOR_REVIEW": "提出前（下書き）",
        "WAITING_FOR_REVIEW": "審査待ち",
        "IN_REVIEW": "審査中",
        "UNRESOLVED_ISSUES": "未解決の問題あり",
        "CANCELING": "取り消し中",
        "COMPLETING": "完了の処理中",
        "COMPLETE": "完了",
    ]

    static let liveStates: Set<String> = ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PREORDER_READY_FOR_SALE"]

    public static func versionLabel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "不明" }
        return versionLabels[raw] ?? raw
    }

    public static func submissionLabel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "不明" }
        return submissionLabels[raw] ?? raw
    }

    public static func isLive(_ raw: String?) -> Bool {
        raw.map(liveStates.contains) ?? false
    }

    public static func versionTone(_ raw: String?) -> AppStoreStateTone {
        switch raw {
        case "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED": return .editing
        case "WAITING_FOR_REVIEW", "WAITING_FOR_EXPORT_COMPLIANCE", "PENDING_CONTRACT": return .waiting
        case "IN_REVIEW": return .inReview
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY": return .rejected
        case "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PENDING_RELEASE", "PROCESSING_FOR_APP_STORE",
             "PROCESSING_FOR_DISTRIBUTION", "ACCEPTED": return .pendingRelease
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PREORDER_READY_FOR_SALE": return .live
        case "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION", "REPLACED_WITH_NEW_INFO",
             "NOT_APPLICABLE": return .inactive
        default: return .unknown
        }
    }

    public static func submissionTone(_ raw: String?) -> AppStoreStateTone {
        switch raw {
        case "READY_FOR_REVIEW": return .editing
        case "WAITING_FOR_REVIEW", "CANCELING", "COMPLETING": return .waiting
        case "IN_REVIEW": return .inReview
        case "UNRESOLVED_ISSUES": return .rejected
        case "COMPLETE": return .inactive
        default: return .unknown
        }
    }

    /// 編集できる（メタデータを書き換えられる）版の状態。appstore-plugin の判定と同じ。
    public static let editableStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "METADATA_REJECTED", "DEVELOPER_REJECTED", "REJECTED", "INVALID_BINARY", "DEVELOPER_REMOVED_FROM_SALE",
    ]

    public static func platformLabel(_ raw: String?) -> String {
        switch raw {
        case "IOS": return "iOS"
        case "MAC_OS": return "macOS"
        case "TV_OS": return "tvOS"
        case "VISION_OS": return "visionOS"
        case let raw?: return raw
        case nil: return "-"
        }
    }
}
