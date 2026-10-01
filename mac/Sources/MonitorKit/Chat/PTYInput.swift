import Foundation

/// アプリがホストする Claude Code（TUI）へ PTY で送るキー列。値は実機の TUI（v2.1.251）で確認済み。
public enum PTYInput {
    /// 権限プロンプトの「1. Yes」。数字キーで即決定される。
    public static let allowKey = "1"
    /// 権限プロンプトの「Esc to cancel」。選択肢の数（No の番号）が場合で変わるので Esc で拒否する。
    public static let denyKey = "\u{1b}"
    /// 送信（入力欄で Enter）。
    public static let submitKey = "\r"
    /// 選択メニューの取り消し（操作案内の「Esc to cancel」）。
    public static let cancelMenuKey = "\u{1b}"
    /// 選択メニューで ❯ のある選択肢を確定する（操作案内の「Enter to select / confirm」）。
    public static let confirmMenuKey = "\r"
    /// 矢印キーを 1 つずつ送り、画面で ❯ の動きを確かめてから次を送る間隔。
    public static let menuStepInterval: TimeInterval = 0.1

    /// 矢印キー。端末がアプリケーションカーソルモード（DECCKM）なら SS3、そうでなければ CSI（実キーボードと同じ列）。
    public static func arrowKey(_ direction: MenuNavigator.Direction, applicationCursor: Bool) -> String {
        let final = direction == .up ? "A" : "B"
        return (applicationCursor ? "\u{1b}O" : "\u{1b}[") + final
    }

    /// AskUserQuestion のタブ移動（Tabs の既定の割り当て: → が tabs:next、← が tabs:previous。v2.1.286）。
    /// Tab キーは複数選択では選択肢の移動に取られるので使わない。
    public static func tabKey(_ direction: MenuTabMover.Direction, applicationCursor: Bool) -> String {
        let final = direction == .next ? "C" : "D"
        return (applicationCursor ? "\u{1b}O" : "\u{1b}[") + final
    }

    /// 貼り付けと Enter を同時に送ると Enter が貼り付けに飲まれるので、少し空ける。
    public static let submitDelay: TimeInterval = 0.3

    /// 入力欄に入れる本文。bracketed paste なら改行を含めたまま 1 回の貼り付けとして届く（Enter で送信されない）。
    /// 返り値が nil なら送るものが無い。
    public static func messageBody(_ text: String, bracketedPaste: Bool) -> String? {
        var body = sanitize(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if bracketedPaste {
            return "\u{1b}[200~" + body + "\u{1b}[201~"
        }
        // 貼り付けモードでない端末では改行が送信になるので、1 行に畳む。
        return body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// 改行とタブ以外の制御文字（C0・DEL・C1）を落とす。ESC や Ctrl-C 等が本文から端末操作として効かないようにするため。
    public static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isControl(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x00...0x1F, 0x7F, 0x80...0x9F: return true
        default: return false
        }
    }
}

/// 入力欄への送信（Enter）を止めるべき端末画面の状態。
public enum InputBlock: Sendable, Equatable {
    /// ツール使用の権限プロンプト。Enter が「1. Yes」になる。
    case permission
    /// 選択メニュー（plan の承認・AskUserQuestion・フォルダの trust 確認など）。Enter が選択中の項目になる。中身は `ChoiceMenu.parse`。
    case menu

    /// 画面から判定する（権限プロンプトを優先）。止めなくてよければ nil。
    public static func detect(screen: [String]) -> InputBlock? {
        if PermissionPrompt.parse(screen: screen) != nil { return .permission }
        if ChoiceMenu.isShowing(screen: screen) { return .menu }
        return nil
    }

    /// 状態バッジ用の「入力待ち」文言（小文字・部分一致）。返答本文に出うる言い回しは入れない。送信判定には使わない。
    public static let waitingPhrases: [String] = [
        "yes, and don't ask again",
        "no, and tell claude",
        "❯ 1. yes",
    ]

    /// 画面下部の文言だけで入力待ちに見えるか（バッジ用）。
    public static func looksWaiting(tail: String) -> Bool {
        let lowered = tail.lowercased()
        return waitingPhrases.contains { lowered.contains($0) }
    }
}

/// 端末画面に出ている選択メニュー（❯ で選ぶもの）の判定。値は TUI v2.1.286 で確認。
public enum ChoiceMenu {
    /// 見る範囲（末尾の空行を除いた画面の下から）。メニューは常に描画済みの最下部に出る。
    static let tailLines = 30
    /// メニューの操作案内（行頭）。trust 確認のように番号の無いメニューはこれで見分ける。
    static let footerPrefixes = ["enter to confirm", "enter to select", "enter to continue", "esc to cancel", "esc to exit"]

    public static func isShowing(screen: [String]) -> Bool {
        var lines = Array(TerminalScreen.droppingTrailingBlankLines(screen).suffix(tailLines)).map { $0.trimmingCharacters(in: .whitespaces) }
        // 下部に入力欄があれば、それより上は会話の履歴、欄の中は入力中の文なので見ない。
        if let start = InputBox.zoneStart(lines) {
            lines = Array(lines[start...])
        }
        let footerZone = lines.filter { !$0.isEmpty }.suffix(8)
        if footerZone.contains(where: { line in footerPrefixes.contains { line.lowercased().hasPrefix($0) } }) { return true }
        return hasNumberedChoices(lines)
    }

    /// 「❯ n. …」の近くに n±1 の選択肢が並んでいるか。
    static func hasNumberedChoices(_ lines: [String]) -> Bool {
        for (index, line) in lines.enumerated() {
            guard let number = choiceNumber(line, cursor: true) ?? emptyFreeTextNumber(line) else { continue }
            let window = lines[max(0, index - 6)..<min(lines.count, index + 7)]
            if window.contains(where: { other in
                guard let n = choiceNumber(other, cursor: false) else { return false }
                return n == number + 1 || n == number - 1
            }) { return true }
        }
        return false
    }

    /// 自由入力の行に ❯ が乗って文字が空の時の「❯ n.」。案内行が出ていなくても入力欄への送信を止めるため、判定にだけ使う。
    static func emptyFreeTextNumber(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("❯") else { return nil }
        let rest = trimmed.dropFirst().drop(while: \.isWhitespace)
        guard rest.last == "." else { return nil }
        let digits = rest.dropLast()
        guard (1...2).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// 選択肢の番号。`cursor` なら ❯ の付いた行だけを見る。
    static func choiceNumber(_ line: String, cursor: Bool) -> Int? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("❯") {
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        } else if cursor {
            return nil
        }
        let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.first == ".", after.dropFirst().first?.isWhitespace == true else { return nil }
        return Int(digits)
    }
}

/// 端末下部の入力欄（罫線の直下の ❯ 行から次の罫線まで）。
public enum InputBox {
    /// 入力欄の ❯ 行の位置。選択肢の形（❯ n. …）の行は、下を罫線で閉じている時だけ入力欄とみなす（番号付きの文を入力中）。
    /// 選択メニューは ❯ の下を罫線で閉じない（v2.1.286: 入力欄は上下に罫線、plan 承認は上だけ、
    /// AskUserQuestion の区切り線は「Chat about this」の上で、その下は操作案内）。
    static func promptIndex(_ lines: [String]) -> Int? {
        lines.indices.last { index in
            guard index > 0 else { return false }
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("❯"), PermissionPrompt.isSeparator(lines[index - 1]) else { return false }
            return ChoiceMenu.choiceNumber(line, cursor: true) == nil || closingRule(lines, after: index) != nil
        }
    }

    /// 入力欄の下の罫線の位置。間か後ろにメニューの操作案内があれば入力欄ではないので nil。
    static func closingRule(_ lines: [String], after index: Int) -> Int? {
        guard let rule = lines[(index + 1)...].firstIndex(where: { PermissionPrompt.isSeparator($0) || ChoiceMenu.isFooter($0) }),
              PermissionPrompt.isSeparator(lines[rule]),
              !lines[(rule + 1)...].contains(where: ChoiceMenu.isFooter) else { return nil }
        return rule
    }

    /// 入力欄より下（メニューを探してよい範囲）の先頭。入力欄が無ければ nil。
    static func zoneStart(_ lines: [String]) -> Int? {
        guard let prompt = promptIndex(lines) else { return nil }
        return (closingRule(lines, after: prompt) ?? prompt) + 1
    }

    /// 入力欄に入っている文字（空なら ""）。入力欄が見つからなければ nil。空欄の時の薄字の例文（Try "…"）は空とみなす。
    public static func text(screen: [String]) -> String? {
        let lines = TerminalScreen.droppingTrailingBlankLines(screen)
        guard let start = promptIndex(lines) else { return nil }
        var parts: [String] = []
        for (offset, line) in lines[start...].enumerated() {
            if offset > 0, PermissionPrompt.isSeparator(line) { break }
            var t = Substring(line.trimmingCharacters(in: .whitespaces))
            if offset == 0 { t = t.dropFirst().drop(while: \.isWhitespace) }
            if !t.isEmpty { parts.append(String(t)) }
        }
        let text = parts.joined(separator: "\n")
        if parts.count == 1, isPlaceholder(text) { return "" }
        return text
    }

    /// 空欄の時に出る例文（v2.1.286: `Try "fix lint errors"`）。
    static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("Try \"") && text.hasSuffix("\"") && text.count > 6
    }
}

/// 端末画面に出ている権限プロンプト。
public struct PermissionPrompt: Sendable, Equatable {
    /// 「Bash command」「Edit file」等の見出し。
    public var title: String
    /// コマンド・説明などの本文行。
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    /// 画面の行（上から順）から権限プロンプトを読み取る。出ていなければ nil。
    /// 区切り線（─）から「Do you want to …?」の手前までを本文とし、選択肢（1. Yes …）が続くことを確かめる。
    public static func parse(screen: [String]) -> PermissionPrompt? {
        guard let questionIndex = screen.lastIndex(where: { isQuestion($0) }) else { return nil }
        let after = screen[(questionIndex + 1)...].prefix(6)
        guard after.contains(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^(❯\s*)?1\.\s*Yes"#, options: .regularExpression) != nil }) else {
            return nil
        }
        var start = questionIndex
        while start > 0, questionIndex - start < 20 {
            let line = screen[start - 1]
            if isSeparator(line) { break }
            start -= 1
        }
        let body = screen[start..<questionIndex]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Tip:") && !isRule($0, of: "╌") }
        guard let title = body.first else { return PermissionPrompt(title: "権限の確認", lines: []) }
        return PermissionPrompt(title: title, lines: Array(body.dropFirst()))
    }

    static func isQuestion(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("do you want to") && t.hasSuffix("?")
    }

    /// プロンプトの外枠（実線）。コマンドを囲む破線（╌）は枠の内側なので境界にしない。
    static func isSeparator(_ line: String) -> Bool {
        isRule(line, of: "─") || isRule(line, of: "━")
    }

    static func isRule(_ line: String, of character: Character) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.allSatisfy { $0 == character }
    }
}

/// 端末バッファの読み出しの補助。
public enum TerminalScreen {
    /// 末尾の空行を落とす。端末が縦に長いと TUI は上詰めで描くので、下の空行で見る範囲がずれないようにする。
    public static func droppingTrailingBlankLines(_ screen: [String]) -> [String] {
        var end = screen.count
        while end > 0, screen[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return Array(screen[..<end])
    }

    /// `exists(i)` が「i < 行数」の時だけ true になる前提で、行数を指数探索 + 二分探索で求める（呼び出しは O(log 行数)）。
    public static func lineCount(rows: Int, exists: (Int) -> Bool) -> Int {
        guard exists(0) else { return 0 }
        var low = max(0, rows - 1)
        guard exists(low) else {
            return (0..<rows).first { !exists($0) } ?? rows
        }
        var high = low + 1
        while exists(high) {
            low = high
            high *= 2
        }
        while high - low > 1 {
            let mid = (low + high) / 2
            if exists(mid) { low = mid } else { high = mid }
        }
        return high
    }
}
