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

    /// 新しい順の履歴。本人の発話（伝言の写し・アプリが自分で頼む続きの依頼を除く）と、まだ記録されていない送信中の発話。
    /// 同じ文の連続は 1 つにする。`now`（epoch ミリ秒）があれば期限切れの送信中の発話を除く。
    public static func entries(items: [TranscriptItem], notes: [RelayNote] = [], sent: [Sent] = [], now: Double? = nil) -> [String] {
        let users = (notes.isEmpty ? items : RelayNotes.removingEchoes(from: items, notes: notes)).filter { item in
            item.kind == .user && !(item.text ?? "").hasPrefix(RelayNotes.peerPrefix)
        }
        var oldestFirst = users.map { recallable($0.text ?? "") }
        oldestFirst += pending(sent, in: items, now: now).map { recallable($0.text) }
        var result: [String] = []
        for text in oldestFirst.reversed() where !text.isEmpty && text != result.last && text != SessionRestore.continueMessage {
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

    /// 履歴に出す送信中の発話。記録されたもの・期限切れ・最後に記録された発話より前に送ったもの（取り下げ等で記録されなかった）を除く。
    public static func pending(_ sent: [Sent], in items: [TranscriptItem], now: Double?) -> [Sent] {
        guard !sent.isEmpty else { return [] }
        let lastRecorded = items.lazy.filter { $0.kind == .user }.compactMap(\.at).max()
        return unrecorded(sent, in: items).filter { sent in
            if let now, now - sent.sentAt >= sentLifetime { return false }
            if let lastRecorded, sent.sentAt < lastRecorded { return false }
            return true
        }
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

/// 入力欄の ↑ / ↓ による履歴の呼び出しの状態（シェルの履歴と同じ動き）。ルームごとに持つ。
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

    /// 今出している履歴の位置（0 が一番新しい）。nil は辿っていない（呼び出した文が欄に残っていても、ルームを替えた後は初めから辿る）。
    public private(set) var position: Int?
    /// 呼び出す前の打ちかけの下書き。nil は呼び出していない。
    public private(set) var savedDraft: String?
    private var shown: String?
    /// 辿っている間の履歴（新しい順）と、組み立てた時の transcript などの印。
    private var history: [String] = []
    private var stamp: String?

    public init() {}

    /// 呼び出した文も退避した下書きも無い（持っておく必要が無い）。
    public var isIdle: Bool { savedDraft == nil && shown == nil }

    /// 履歴に回せる位置か。カーソルが先頭で選択が無く、変換中でない時だけ。
    public static func isAtStart(selection: NSRange, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && selection.location == 0 && selection.length == 0
    }

    /// `current` は今の入力欄の文。`stamp` は履歴の元が変わったら変わる印、`history` は新しい順の履歴で、要る時だけ呼ぶ。
    public mutating func move(_ direction: Direction, current: String, stamp: () -> String,
                              history build: () -> [String]) -> Outcome {
        // 呼び出した文を打ち直したら、その文を新しい下書きとして呼び出しをやめる。
        if let shown, current != shown { reset() }
        switch direction {
        case .older:
            refresh(stamp: stamp, build: build)
            let next: Int
            if let position {
                next = position + 1
            } else {
                // 欄に出ている文と同じものは飛ばす（ルームを替えて戻った時に同じ文を出し直さない）。
                next = history.first == current ? 1 : 0
            }
            guard next < history.count else { return savedDraft == nil ? .pass : .stay }
            if savedDraft == nil { savedDraft = current }
            return show(next)
        case .newer:
            guard savedDraft != nil else { return .pass }
            guard position != nil else { return restoreDraft() }
            refresh(stamp: stamp, build: build)
            guard let position, position > 0 else { return restoreDraft() }
            return show(position - 1)
        }
    }

    /// ルームやタブを離れた。位置は初めに戻すが、欄に残る呼び出した文と退避した下書きは覚えておき、↓ で戻せるようにする。
    public mutating func rewind() {
        position = nil
        history = []
        stamp = nil
    }

    public mutating func reset() {
        self = ComposerRecall()
    }

    /// 辿り始めと履歴の元が変わった時だけ組み立て直し、今出している文を基準に位置を合わせ直す。
    private mutating func refresh(stamp: () -> String, build: () -> [String]) {
        let newStamp = stamp()
        guard position == nil || newStamp != self.stamp else { return }
        let fresh = build()
        if let position { self.position = Self.reanchor(position, shown: shown, old: history, new: fresh) }
        history = fresh
        self.stamp = newStamp
    }

    static func reanchor(_ position: Int, shown: String?, old: [String], new: [String]) -> Int? {
        guard !new.isEmpty else { return nil }
        // 新しい発話は先頭に足されるので、古い一覧がそのまま後ろに残っていればその分だけずらす。
        if new.count >= old.count, Array(new.suffix(old.count)) == old { return position + new.count - old.count }
        if let shown, let nearest = new.indices.filter({ new[$0] == shown }).min(by: { abs($0 - position) < abs($1 - position) }) {
            return nearest
        }
        return min(position, new.count - 1)
    }

    private mutating func show(_ index: Int) -> Outcome {
        position = index
        shown = history[index]
        return .show(history[index])
    }

    private mutating func restoreDraft() -> Outcome {
        let draft = savedDraft ?? ""
        reset()
        return .show(draft)
    }
}

extension NSTextView {
    /// 呼び出した文に入れ替える。打った時と同じく取り消しと変更の通知（下書きへの反映）を通し、カーソルは先頭に置く。
    public func replaceAllForRecall(with text: String) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        // 直前の打鍵とまとめず、⌘Z 1 回で入れ替え前に戻るようにする。
        breakUndoCoalescing()
        if shouldChangeText(in: whole, replacementString: text) {
            replaceCharacters(in: whole, with: text)
            didChangeText()
        }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
