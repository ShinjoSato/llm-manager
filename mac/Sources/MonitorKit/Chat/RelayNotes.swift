import Foundation

/// アプリから外部セッションへ送った伝言 1 通。
public struct RelayNote: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case sending
        case sent
        case failed(String)
    }

    public var id: String
    public var text: String
    /// 送った時刻（epoch ミリ秒）。会話の並びに差し込む位置に使う。
    public var sentAt: Double
    public var state: State
    /// 添えた画像の一時ファイル（受け手にはパスで渡り、吹き出しには画像で出す）。
    public var imagePaths: [String]

    public init(id: String = UUID().uuidString, text: String, sentAt: Double, state: State = .sending, imagePaths: [String] = []) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.state = state
        self.imagePaths = imagePaths
    }
}

public enum RelayNotes {
    /// 受信側が伝言の前に付ける書き出し（Claude Code v2.1.286）。
    public static let peerPrefix = "Another Claude session sent a message:"
    /// 送信時刻より前に記録されたと見なしてよい時計のずれ（ミリ秒）。
    static let clockSlack: Double = 5_000
    /// 書き出し無しで同じ文面が出た時に写しと見なす時間（ミリ秒）。作業中は伝言がキューで待つので長めに取る。
    static let plainEchoWindow: Double = 10 * 60_000

    /// monitor は受信箱へ送る前に前後の空白を落とすので、照合も同じ形にそろえる。
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// transcript の発話が伝言の写しか（isMeta 行を出すようになっても二重に並べないため）。
    public static func isEcho(_ item: TranscriptItem, of note: RelayNote) -> Bool {
        guard item.kind == .user, let raw = item.text else { return false }
        if let at = item.at, at < note.sentAt - clockSlack { return false }
        let text = normalized(raw)
        let body = normalized(note.text)
        guard !body.isEmpty else { return false }
        // 本人の発話を消さないよう、素の一致は時刻があり送信直後のものに限る。
        if text == body { return item.at.map { $0 <= note.sentAt + plainEchoWindow } ?? false }
        guard text.hasPrefix(peerPrefix) else { return false }
        let rest = normalized(String(text.dropFirst(peerPrefix.count)))
        return rest == body || rest.hasPrefix(body + "\n")
    }

    /// 伝言の写しを transcript から取り除く（1 通につき 1 件まで）。
    public static func removingEchoes(from items: [TranscriptItem], notes: [RelayNote]) -> [TranscriptItem] {
        // 届かなかった伝言には写しが無いので、同じ文面の本人の発話を消さない。
        var pending = notes.filter { if case .failed = $0.state { return false } else { return true } }
        var result: [TranscriptItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            if let index = pending.firstIndex(where: { isEcho(item, of: $0) }) {
                pending.remove(at: index)
                continue
            }
            result.append(item)
        }
        return result
    }

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
