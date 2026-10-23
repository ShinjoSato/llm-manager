import AppKit

/// 入力欄の ↑ / ↓ で呼び出す、そのルームで前に送った発話の一覧。
public enum ComposerHistory {
    /// アプリから送り、まだ transcript に載っていない発話。
    public struct Sent: Sendable, Equatable, Identifiable {
        public var id: String
        public var text: String
        /// 送り始めた時刻（epoch ミリ秒）。
        public var sentAt: Double

        public init(id: String = UUID().uuidString, text: String, sentAt: Double) {
            self.id = id
            self.text = text
            self.sentAt = sentAt
        }
    }

    /// 送信より前に記録されたと見なしてよい時計のずれ（ミリ秒）。
    static let clockSlack: Double = 5_000
    /// 記録を待つ長さ。作業中はキューで待つので長めに取り、それを過ぎたら届かなかったものとして持たない。
    public static let sentLifetime: Double = 30 * 60_000
    /// ルームごとに覚えておく送信中の発話の数。
    public static let sentLimit = 20

    /// 新しい順の履歴。本人の発話（伝言の写しを除く）と、まだ記録されていない送信中の発話。同じ文の連続は 1 つにする。
    public static func entries(items: [TranscriptItem], notes: [RelayNote] = [], sent: [Sent] = []) -> [String] {
        let users = (notes.isEmpty ? items : RelayNotes.removingEchoes(from: items, notes: notes)).filter { item in
            item.kind == .user && !(item.text ?? "").hasPrefix(RelayNotes.peerPrefix)
        }
        var oldestFirst = users.map { recallable($0.text ?? "") }
        oldestFirst += unrecorded(sent, in: users).map { recallable($0.text) }
        var result: [String] = []
        for text in oldestFirst.reversed() where !text.isEmpty && text != result.last {
            result.append(text)
        }
        return result
    }

    /// 送信中の発話のうち、まだ transcript に載っていないもの（古い順に 1 発話 1 通で突き合わせる）。
    public static func unrecorded(_ sent: [Sent], in items: [TranscriptItem]) -> [Sent] {
        var pending = sent.sorted { $0.sentAt < $1.sentAt }
        for item in items where item.kind == .user {
            guard !pending.isEmpty else { break }
            let text = recallable(item.text ?? "")
            if let index = pending.firstIndex(where: { isRecorded(text: text, at: item.at, of: $0) }) { pending.remove(at: index) }
        }
        return pending
    }

    private static func isRecorded(text: String, at: Double?, of sent: Sent) -> Bool {
        if let at, at < sent.sentAt - clockSlack { return false }
        return text == recallable(sent.text)
    }

    /// 送った時の形から入力欄に戻す形にする。添付は呼び出さないので、画像の印と末尾のファイルの一覧を外す。
    public static func recallable(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: #"\[Image #\d+\] ?"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != ChatImageText.placeholder }
        if let header = lines.lastIndex(where: { $0 == AttachmentFormat.listHeader }),
           header == 0 || lines[header - 1].trimmingCharacters(in: .whitespaces).isEmpty,
           header < lines.count - 1, lines[(header + 1)...].allSatisfy({ isListedPath($0) }) {
            lines.removeSubrange(header...)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListedPath(_ line: String) -> Bool {
        line.hasPrefix("/") || line.hasPrefix("\"/")
    }

    /// 送信中の発話を足す（古いもの・多すぎる分は捨てる）。
    public static func appending(_ new: Sent, to sent: [Sent]) -> [Sent] {
        let kept = sent.filter { new.sentAt - $0.sentAt < sentLifetime } + [new]
        return Array(kept.suffix(sentLimit))
    }
}

/// 入力欄の ↑ / ↓ による履歴の呼び出しの状態（シェルの履歴と同じ動き）。
public struct ComposerRecall: Sendable, Equatable {
    public enum Direction: Sendable { case older, newer }

    public enum Outcome: Sendable, Equatable {
        /// 履歴には回さず、既定の ↑ / ↓（行の移動）にする。
        case pass
        /// キーは受けるが文は変えない（一番古い履歴で ↑）。
        case stay
        /// 入力欄をこの文に入れ替え、カーソルを先頭に置く。
        case show(String)
    }

    /// 今出している履歴の位置（0 が一番新しい）。nil は呼び出していない。
    public private(set) var position: Int?
    /// 呼び出す前の打ちかけの下書き。
    public private(set) var savedDraft = ""
    private var shown: String?

    public init() {}

    /// 履歴に回せる位置か。カーソルが先頭で選択が無く、変換中でない時だけ。
    public static func isAtStart(selection: NSRange, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && selection.location == 0 && selection.length == 0
    }

    /// `history` は新しい順、`current` は今の入力欄の文。
    public mutating func move(_ direction: Direction, history: [String], current: String) -> Outcome {
        // 呼び出した文を打ち直したら、その文を新しい下書きとして呼び出しをやめる。
        if let shown, current != shown { reset() }
        switch direction {
        case .older:
            let next = position.map { $0 + 1 } ?? 0
            guard next < history.count else {
                guard position != nil else { return .pass }
                // 履歴が減って今の位置も無くなった時は一番古いものに合わせる。
                return history.isEmpty ? restoreDraft() : show(history.count - 1, of: history, unlessAt: true)
            }
            if position == nil { savedDraft = current }
            return show(next, of: history, unlessAt: false)
        case .newer:
            guard let position else { return .pass }
            let next = min(position, history.count) - 1
            guard next >= 0 else { return restoreDraft() }
            return show(next, of: history, unlessAt: false)
        }
    }

    public mutating func reset() {
        position = nil
        savedDraft = ""
        shown = nil
    }

    private mutating func show(_ index: Int, of history: [String], unlessAt stayIfSame: Bool) -> Outcome {
        if stayIfSame, position == index, shown == history[index] { return .stay }
        position = index
        shown = history[index]
        return .show(history[index])
    }

    private mutating func restoreDraft() -> Outcome {
        let draft = savedDraft
        reset()
        return .show(draft)
    }
}

extension NSTextView {
    /// 呼び出した文に入れ替える。打った時と同じく取り消しと変更の通知（下書きへの反映）を通し、カーソルは先頭に置く。
    public func replaceAllForRecall(with text: String) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: whole, replacementString: text) {
            replaceCharacters(in: whole, with: text)
            didChangeText()
        }
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
