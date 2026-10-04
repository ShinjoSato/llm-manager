import Foundation

/// 吹き出しに出す画像 1 枚の出どころ。
public enum ChatImage: Sendable, Hashable, Identifiable {
    /// transcript の発話に添えられた画像（アプリ内の監視から取る）。
    case transcript(itemId: String, index: Int)
    /// アプリから送った画像の手元の一時ファイル。
    case file(String)

    public var id: String {
        switch self {
        case .transcript(let itemId, let index): return "t:\(itemId):\(index)"
        case .file(let path): return "f:\(path)"
        }
    }
}

public enum ChatImageText {
    /// 監視が画像ブロックの代わりに本文へ入れる印。
    public static let placeholder = "[画像]"

    /// 画像を出せる時は、その枚数ぶんの印の行を本文から外す（印だけの発話は空になる）。
    public static func removingPlaceholders(_ text: String, count: Int) -> String {
        guard count > 0 else { return text }
        var remaining = count
        let lines = text.components(separatedBy: "\n").filter { line in
            guard remaining > 0, line.trimmingCharacters(in: .whitespaces) == placeholder else { return true }
            remaining -= 1
            return false
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// アプリから画像を添えて送り、まだ transcript に載っていない発話。載るまでの間、送った画像を吹き出しに出す。
public struct PendingImageMessage: Sendable, Equatable, Identifiable {
    public var id: String
    /// 吹き出しに出す本文（入力欄に書いたもの）。
    public var text: String
    /// 端末へ実際に送った本文（パスで添えたファイルの一覧を含む）。記録との突き合わせに使う。
    public var sentBody: String
    /// 端末へ画像として貼った一時ファイル。
    public var imagePaths: [String]
    /// 送り始めた時刻（epoch ミリ秒）。
    public var sentAt: Double

    public init(id: String = UUID().uuidString, text: String, sentBody: String? = nil, imagePaths: [String], sentAt: Double) {
        self.id = id
        self.text = text
        self.sentBody = sentBody ?? text
        self.imagePaths = imagePaths
        self.sentAt = sentAt
    }
}

public enum PendingImageMessages {
    /// 送信より前に記録されたと見なしてよい時計のずれ（ミリ秒）。
    static let clockSlack: Double = 5_000
    /// これだけ待っても記録されなければ下げる（キューの取り下げ・捨てられた Enter で永遠に残さない）。
    public static let lifetime: Double = 3 * 60 * 1000

    /// 画像として貼った分があれば、記録されるまで出す発話。パスとして本文に回った画像だけなら記録に画像が付かないので出さない。
    public static func outgoing(id: String = UUID().uuidString, text: String, sentBody: String, pastedImagePaths: [String],
                                sentAt: Double) -> PendingImageMessage? {
        guard !pastedImagePaths.isEmpty else { return nil }
        return PendingImageMessage(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), sentBody: sentBody,
                                   imagePaths: pastedImagePaths, sentAt: sentAt)
    }

    /// 突き合わせ用の本文。画像の印（`[Image #N]`・`[画像]`）と空白・制御文字を除く。
    static func normalized(_ text: String) -> String {
        let withoutMarks = text
            .replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ChatImageText.placeholder, with: "")
        return String(withoutMarks.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0.properties.generalCategory != .control
        }.map(Character.init))
    }

    /// transcript の発話が、送った画像付きの発話の記録か（送った後の本人の発話で、画像の枚数と本文が一致する）。
    public static func isRecorded(_ item: TranscriptItem, of message: PendingImageMessage) -> Bool {
        guard item.kind == .user, item.images.count == message.imagePaths.count, let at = item.at else { return false }
        guard at >= message.sentAt - clockSlack else { return false }
        return normalized(item.text ?? "") == normalized(message.sentBody)
    }

    public static func isExpired(_ message: PendingImageMessage, now: Double) -> Bool {
        now - message.sentAt >= lifetime
    }

    /// まだ transcript に載っていないもの。1 件の発話は 1 通にだけ対応させる（古い順に突き合わせる）。
    /// `now` を渡すと期限切れも除く。
    public static func unrecorded(_ messages: [PendingImageMessage], in items: [TranscriptItem],
                                  now: Double? = nil) -> [PendingImageMessage] {
        guard !messages.isEmpty else { return [] }
        var pending = messages.sorted { $0.sentAt < $1.sentAt }
        if let now { pending.removeAll { isExpired($0, now: now) } }
        for item in items where item.kind == .user && !item.images.isEmpty {
            if pending.isEmpty { break }
            if let index = pending.firstIndex(where: { isRecorded(item, of: $0) }) { pending.remove(at: index) }
        }
        return pending
    }
}
