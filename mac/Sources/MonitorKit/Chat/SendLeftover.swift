import CryptoKit
import Foundation

/// 取りやめた送信の残りが端末の入力欄にあるかもしれない時の、次の送信の扱い。
public enum LeftoverCheck: Sendable, Equatable {
    case none
    /// 残りがあれば 1 回だけ知らせる（未知の薄字表示を本文と誤認しても、もう一度送れば送れる）。
    case warnOnce
    /// 貼り付けが入らなかった送信の後。遅れて入った本文と戻した本文が二重にならないよう、入力欄が貼る前（`baseline`）か空と確かめるまで送らない。
    /// `body` は入らなかった本文（貼り付けの印を除いたもの）。入力欄に見えているかを確かめるためだけに持ち、記録には書かない。
    case untilClear(baseline: String, body: String)

    public enum Decision: Sendable, Equatable {
        case send
        /// `strict` は確かめられるまで何度でも止める側。
        case refuse(strict: Bool)
    }

    /// 入力欄を読めない状態がこれだけ続いたら、確かめられないまま送るのを選べるようにする（永遠に詰まらせないため）。
    public static let forceAfter: TimeInterval = 30

    /// 今の入力欄（読めなければ nil）から、送るかと次の状態を決める。
    public func decide(box: String?) -> (Decision, next: LeftoverCheck) {
        switch self {
        case .none:
            return (.send, .none)
        case .warnOnce:
            // 入力欄が読めない時は残りを確かめられないが、くっつく害は小さいので送る（印は残す）。
            guard let box else { return (.send, .warnOnce) }
            return (box.isEmpty ? .send : .refuse(strict: false), .none)
        case .untilClear(let baseline, _):
            guard let box, box.isEmpty || box == baseline else { return (.refuse(strict: true), self) }
            return (.send, .none)
        }
    }

    /// 入らなかった本文が今の入力欄に見えているか（そのまま Enter で送ってよいか）。
    public func showsBody(box: String?) -> Bool {
        guard case .untilClear(let baseline, let body) = self, let box else { return false }
        return InputBoxMatch.showsBody(box: box, baseline: baseline, body: body)
    }

    /// 確かめられるまで止めている間の抜け道（止めていなければ nil）。`unreadableFor` は入力欄を読めない状態が続いている秒数。
    public func escape(box: String?, unreadableFor: TimeInterval) -> LeftoverEscape? {
        guard case .untilClear = self, decide(box: box).0 != .send else { return nil }
        guard box != nil else { return LeftoverEscape(box: .unreadable, canForce: unreadableFor >= Self.forceAfter) }
        return LeftoverEscape(box: showsBody(box: box) ? .showsBody : .other, canForce: false)
    }

    /// 入らなかった本文（確かめている間だけ）。
    public var lateBody: String? {
        guard case .untilClear(_, let body) = self else { return nil }
        return body
    }

    /// 記録に書く名前。
    public var logName: String {
        switch self {
        case .none: return "none"
        case .warnOnce: return "warnOnce"
        case .untilClear: return "untilClear"
        }
    }
}

/// 送らずに止めている間に出す抜け道。
public struct LeftoverEscape: Sendable, Equatable {
    public enum Box: Sendable, Equatable {
        /// 入力欄を読めない。
        case unreadable
        /// 入らなかった本文が入力欄に見えている（そのまま送れる）。
        case showsBody
        /// 何か入っているが、入らなかった本文とは確かめられない。
        case other
    }

    public var box: Box
    /// 読めない状態が長く続き、確かめられないまま送るのを選べる。
    public var canForce: Bool

    public init(box: Box, canForce: Bool) {
        self.box = box
        self.canForce = canForce
    }

    public var canSubmitAsIs: Bool { box == .showsBody }
}

/// 入力欄を読めない状態がいつから続いているか。
public struct UnreadableSpan: Sendable, Equatable {
    public private(set) var since: Date?

    public init() {}

    /// 今の読み取りを足し、読めない状態が続いている秒数を返す（読めたら 0 に戻す）。
    public mutating func observe(readable: Bool, now: Date) -> TimeInterval {
        guard !readable else {
            since = nil
            return 0
        }
        let start = since ?? now
        since = start
        return now.timeIntervalSince(start)
    }

    public mutating func reset() { since = nil }
}

/// 入力欄の文字と本文の突き合わせ。端末の折り返しで空白や改行の位置が変わるので、空白を除いて比べる。
public enum InputBoxMatch {
    /// `box` の `baseline`（貼る前）より後ろに `body` が入っているか。長文は `[Pasted text #N …]` に畳まれるので、新しい畳みの印も本文とみなす。
    public static func showsBody(box: String, baseline: String, body: String) -> Bool {
        let shown = compact(box)
        let before = compact(baseline)
        let added = !before.isEmpty && shown.hasPrefix(before) ? String(shown.dropFirst(before.count)) : shown
        let target = compact(body)
        guard !added.isEmpty, !target.isEmpty else { return false }
        if added.contains(target) { return true }
        return foldedCount(shown) > foldedCount(before)
    }

    /// 畳まれた貼り付けの表示か。
    public static func isFolded(_ box: String) -> Bool { foldedCount(compact(box)) > 0 }

    static func foldedCount(_ compacted: String) -> Int {
        compacted.components(separatedBy: "[Pastedtext#").count - 1
            + compacted.components(separatedBy: "[...Truncatedtext#").count - 1
    }

    static func compact(_ text: String) -> String {
        PasteCheck.plainText(text).filter { !$0.isWhitespace }
    }
}

/// 送信の記録（send-ops.log）に書く項目。本文は書かず、長さ・指紋・形だけにする。
public enum SendOpsFields {
    /// 本文の長さ・行数と SHA-256 の先頭 8 桁。
    public static func text(_ text: String, prefix: String) -> [(String, String)] {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return [("\(prefix)Len", "\(text.count)"), ("\(prefix)Lines", "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)"),
                ("\(prefix)Sha", String(digest.prefix(8)))]
    }

    /// 入力欄の読み取り結果（読めたか・長さ・指紋・本文を含むか・畳まれた表示か・画像の印の数）。
    public static func box(_ box: String?, body: String?, baseline: String?, prefix: String = "box") -> [(String, String)] {
        guard let box else { return [(prefix, "unreadable")] }
        if box.isEmpty { return [(prefix, "empty")] }
        var fields: [(String, String)] = [(prefix, "text")] + text(box, prefix: prefix)
        if let body {
            fields.append(("\(prefix)HasBody", InputBoxMatch.showsBody(box: box, baseline: baseline ?? "", body: body) ? "yes" : "no"))
        }
        fields.append(("\(prefix)Folded", InputBoxMatch.isFolded(box) ? "yes" : "no"))
        fields.append(("\(prefix)Images", "\(AttachmentFormat.imageTokenCount(in: box))"))
        if let baseline { fields.append(("\(prefix)SameAsBefore", box == baseline ? "yes" : "no")) }
        return fields
    }

    /// 入力欄まわりの画面の形（罫線・❯ 行・案内行・作業中の表示の有無と位置。文字は書かない）。読み取りに失敗した時の手がかりにする。
    public static func shape(_ screen: [String]) -> [(String, String)] {
        let lines = Array(TerminalScreen.droppingTrailingBlankLines(screen).suffix(ChoiceMenu.tailLines))
        let rules = lines.indices.filter { PermissionPrompt.isSeparator(lines[$0]) }
        let prompts = lines.indices.filter { lines[$0].trimmed.hasPrefix("❯") }
        let promptsAfterRule = prompts.filter { $0 > 0 && PermissionPrompt.isSeparator(lines[$0 - 1]) }
        let lastRule = rules.last.map { "\(lines.count - 1 - $0)" } ?? "-"
        let lastPrompt = prompts.last.map { "\(lines.count - 1 - $0)" } ?? "-"
        let footer = lines.contains(where: ChoiceMenu.isFooter)
        let spinner = lines.contains(where: ChoiceMenu.isConversationLine)
        let interrupt = lines.contains { $0.lowercased().contains("esc to interrupt") }
        return [("rows", "\(screen.count)"), ("tail", "\(lines.count)"), ("rules", "\(rules.count)"), ("lastRuleUp", lastRule),
                ("prompts", "\(prompts.count)"), ("promptsAfterRule", "\(promptsAfterRule.count)"), ("lastPromptUp", lastPrompt),
                ("footer", footer ? "yes" : "no"), ("replyOrSpinner", spinner ? "yes" : "no"), ("interrupt", interrupt ? "yes" : "no")]
    }
}

/// 送らなかった時に出す選択肢。
public enum LeftoverChoice: Sendable, Equatable {
    /// 「端末の画面」を開く。
    case openTerminal
    /// 端末の入力欄に見えている本文をそのまま Enter で送る。
    case submitAsIs
    /// 端末の入力欄を消す。
    case clearInput
    /// 確かめられないまま送る（確認つき）。
    case forceSend

    /// `strict` は確かめられるまで止める側の断りか。`escape` はその時の抜け道。
    public static func choices(strict: Bool, escape: LeftoverEscape?) -> [LeftoverChoice] {
        guard strict else { return [.openTerminal, .clearInput] }
        var choices: [LeftoverChoice] = [.openTerminal]
        if escape?.canSubmitAsIs == true { choices.append(.submitAsIs) }
        choices.append(.clearInput)
        if escape?.canForce == true { choices.append(.forceSend) }
        return choices
    }
}

extension ComposerRestore {
    /// 入力欄に戻した本文 `restored` と、端末から送った本文 `submitted`（添付の一覧が後ろに付きうる）が同じ送信のものか。
    public static func isSameSend(restored: String, submitted: String) -> Bool {
        let text = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sent.isEmpty else { return text.isEmpty }
        return sent == text || (!text.isEmpty && sent.hasPrefix(text + "\n\n")) || (text.isEmpty && sent.hasPrefix(AttachmentFormat.listHeader))
    }

    /// 端末からそのまま送った本文を、入力欄に戻した書きかけから外す（戻した本文は先頭に置いている）。戻した後に書き換えていれば nil（外さない）。
    public static func draft(removing sent: String, from current: String) -> String? {
        if current == sent { return "" }
        if current.hasPrefix(sent + "\n") { return String(current.dropFirst(sent.count + 1)) }
        return nil
    }
}
