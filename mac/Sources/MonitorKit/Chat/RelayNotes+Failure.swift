import DeckCore
import Foundation

extension RelayNotes {
    /// 送信失敗の理由（監視の失敗種別を画面向けの言葉にする）。
    public static func failureReason(_ error: Error) -> String {
        guard let failure = error as? HubFailure else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        switch failure.code {
        case "not_found": return "このセッションを見失っています（終了した可能性）"
        case "not_alive": return "このセッションは終了しています"
        case "no_socket": return "このセッションには伝言の受け口がありません（受信箱ソケットが見つかりません）"
        case "unreachable": return "セッションに届けられませんでした（\(failure.message)）"
        default: return failure.message
        }
    }
}
