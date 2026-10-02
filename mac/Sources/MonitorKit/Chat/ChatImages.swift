import Foundation

/// 吹き出しに出す画像 1 枚の出どころ。
public enum ChatImage: Sendable, Hashable, Identifiable {
    /// transcript の発話に添えられた画像（monitor から取る）。
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
    /// monitor が画像ブロックの代わりに本文へ入れる印。
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
    public var text: String
    /// 送った画像の一時ファイル。
    public var imagePaths: [String]
    /// 送り始めた時刻（epoch ミリ秒）。
    public var sentAt: Double

    public init(id: String = UUID().uuidString, text: String, imagePaths: [String], sentAt: Double) {
        self.id = id
        self.text = text
        self.imagePaths = imagePaths
        self.sentAt = sentAt
    }
}

public enum PendingImageMessages {
    /// 送信より前に記録されたと見なしてよい時計のずれ（ミリ秒）。
    static let clockSlack: Double = 5_000

    /// transcript の発話が、送った画像付きの発話の記録か（送った後の、画像付きの本人の発話）。
    public static func isRecorded(_ item: TranscriptItem, of message: PendingImageMessage) -> Bool {
        guard item.kind == .user, !item.images.isEmpty, let at = item.at else { return false }
        return at >= message.sentAt - clockSlack
    }

    /// まだ transcript に載っていないもの。1 件の発話は 1 通にだけ対応させる（古い順に突き合わせる）。
    public static func unrecorded(_ messages: [PendingImageMessage], in items: [TranscriptItem]) -> [PendingImageMessage] {
        guard !messages.isEmpty else { return [] }
        var pending = messages.sorted { $0.sentAt < $1.sentAt }
        for item in items where item.kind == .user && !item.images.isEmpty {
            if let index = pending.firstIndex(where: { isRecorded(item, of: $0) }) { pending.remove(at: index) }
            if pending.isEmpty { break }
        }
        return pending
    }
}
