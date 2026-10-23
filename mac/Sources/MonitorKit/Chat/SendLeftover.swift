import CryptoKit
import Foundation

/// 取りやめた送信の残りが端末の入力欄にあるかもしれない時の、次の送信の扱い。
public enum LeftoverCheck: Sendable, Equatable {
    case none
    /// 残りがあれば 1 回だけ知らせる（未知の薄字表示を本文と誤認しても、もう一度送れば送れる）。
    case warnOnce
    /// 貼り付けが入らなかった送信の後。遅れて入った本文と戻した本文が二重にならないよう、入力欄が貼る前（`baseline`）か空と確かめるまで送らない。
    /// `body` は入らなかった本文（貼り付けの印を除いたもの。入力欄に見えるかを確かめるためだけに持ち、記録には書かない）、`id` はその送信の印。
    /// `touched` は止めている間に「端末の画面」から履歴を呼び出しうるキーを送った印（入力欄の中身を本文と取り違えないため）。
    case untilClear(baseline: String, body: String, id: String = "", touched: Bool = false)

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
        case .untilClear(let baseline, _, _, _):
            guard let box, box.isEmpty || box == baseline else { return (.refuse(strict: true), self) }
            return (.send, .none)
        }
    }

    /// 入らなかった本文が今の入力欄にどう見えているか。止めている間に入力欄を触っていれば見えないとみなす。
    public func match(box: String?) -> InputBoxMatch.Match {
        guard case .untilClear(let baseline, let body, _, let touched) = self, !touched, let box else { return .none }
        return InputBoxMatch.match(box: box, baseline: baseline, body: body)
    }

    /// 入らなかった本文が今の入力欄に見えているか（そのまま Enter で送ってよいか）。
    public func showsBody(box: String?) -> Bool { match(box: box) != .none }

    /// 止めている間に入力欄を触った（履歴の呼び出し等）。以後は本文が見えているとはみなさない。
    public var touched: LeftoverCheck {
        guard case .untilClear(let baseline, let body, let id, _) = self else { return self }
        return .untilClear(baseline: baseline, body: body, id: id, touched: true)
    }

    /// 確かめられるまで止めている間の抜け道（止めていなければ nil）。`unreadableFor` は入力欄を読めない状態が続いている秒数。
    public func escape(box: String?, unreadableFor: TimeInterval) -> LeftoverEscape? {
        guard case .untilClear = self, decide(box: box).0 != .send else { return nil }
        guard box != nil else { return LeftoverEscape(box: .unreadable, canForce: unreadableFor >= Self.forceAfter) }
        return LeftoverEscape(box: showsBody(box: box) ? .showsBody : .other, canForce: false)
    }

    /// 入らなかった送信の印（確かめている間だけ）。
    public var lateId: String? {
        guard case .untilClear(_, _, let id, _) = self else { return nil }
        return id
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
    public enum Match: Sendable, Equatable {
        case none
        /// 本文の文字がそのまま見えている（送った本文が同じと確かめられる）。
        case text
        /// 長文が畳まれた印が 1 つだけ増え、その行数が本文と合う（中身までは確かめられない）。
        case folded
    }

    /// `box` の `baseline`（貼る前）より後ろに `body` が入っているか。
    public static func match(box: String, baseline: String, body: String) -> Match {
        let shown = compact(box)
        let before = compact(baseline)
        let added = !before.isEmpty && shown.hasPrefix(before) ? String(shown.dropFirst(before.count)) : shown
        let target = compact(body)
        guard !added.isEmpty, !target.isEmpty else { return .none }
        if added.contains(target) { return .text }
        // 畳みの印は改行の数を `+N lines` に出す（v2.1.309）。増えた印が 1 つだけで、行数が合う時だけ本文とみなす。
        var remaining = foldedTokens(before)
        var new: [Int] = []
        for token in foldedTokens(shown) {
            if let index = remaining.firstIndex(of: token) { remaining.remove(at: index) } else { new.append(token.lines) }
        }
        guard truncatedCount(shown) == truncatedCount(before), new.count == 1 else { return .none }
        return new[0] == body.filter { $0 == "\n" }.count ? .folded : .none
    }

    public static func showsBody(box: String, baseline: String, body: String) -> Bool {
        match(box: box, baseline: baseline, body: body) != .none
    }

    /// 畳まれた貼り付けの表示か。
    public static func isFolded(_ box: String) -> Bool {
        let compacted = compact(box)
        return !foldedTokens(compacted).isEmpty || truncatedCount(compacted) > 0
    }

    struct FoldedToken: Equatable {
        let number: String
        let lines: Int
    }

    /// 空白を除いた文字の中の `[Pastedtext#N+Mlines]`（M が無ければ 0 行）。
    static func foldedTokens(_ compacted: String) -> [FoldedToken] {
        guard let regex = try? NSRegularExpression(pattern: #"\[Pastedtext#(\d+)(?:\+(\d+)lines?)?\]"#) else { return [] }
        let text = compacted as NSString
        return regex.matches(in: compacted, range: NSRange(location: 0, length: text.length)).map { result in
            let lines = result.range(at: 2).location == NSNotFound ? 0 : Int(text.substring(with: result.range(at: 2))) ?? -1
            return FoldedToken(number: text.substring(with: result.range(at: 1)), lines: lines)
        }
    }

    static func truncatedCount(_ compacted: String) -> Int {
        compacted.components(separatedBy: "[...Truncatedtext#").count - 1
    }

    static func compact(_ text: String) -> String {
        PasteCheck.plainText(text).filter { !$0.isWhitespace }
    }
}

/// 送信の記録（send-ops.log）に書く項目。本文は書かず、長さ・指紋・形だけにする。
public enum SendOpsFields {
    /// 起動ごとの鍵（短い本文を辞書で逆算されないよう、指紋は鍵付きにする。同じ起動の中でだけ見比べられる）。
    static let launchKey = SymmetricKey(size: .bits256)

    /// 本文の長さ・行数と、起動ごとの鍵で作った HMAC-SHA256 の先頭 8 桁。
    public static func text(_ text: String, prefix: String) -> [(String, String)] {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: launchKey).map { String(format: "%02x", $0) }.joined()
        return [("\(prefix)Len", "\(text.count)"), ("\(prefix)Lines", "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)"),
                ("\(prefix)Mac", String(code.prefix(8)))]
    }

    /// 入力欄の読み取り結果（読めたか・長さ・指紋・本文を含むか・畳まれた表示か・画像の印の数）。
    public static func box(_ box: String?, body: String?, baseline: String?, prefix: String = "box") -> [(String, String)] {
        guard let box else { return [(prefix, "unreadable")] }
        if box.isEmpty { return [(prefix, "empty")] }
        var fields: [(String, String)] = [(prefix, "text")] + text(box, prefix: prefix)
        if let body {
            let match = InputBoxMatch.match(box: box, baseline: baseline ?? "", body: body)
            fields.append(("\(prefix)HasBody", match == .text ? "text" : match == .folded ? "folded" : "no"))
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
    /// 端末からそのまま送った本文を、入力欄に戻した書きかけから外す（戻した本文は先頭に置いている）。戻した後に書き換えていれば nil（外さない）。
    public static func draft(removing sent: String, from current: String) -> String? {
        if current == sent { return "" }
        if current.hasPrefix(sent + "\n") { return String(current.dropFirst(sent.count + 1)) }
        return nil
    }
}
