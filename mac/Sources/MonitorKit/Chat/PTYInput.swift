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
        cursorKey(direction == .up ? "A" : "B", applicationCursor: applicationCursor)
    }

    /// AskUserQuestion のタブ移動（v2.1.286 の既定は → が tabs:next・← が tabs:previous。Tab は複数選択で選択肢の移動に取られる）。
    public static func tabKey(_ direction: MenuTabMover.Direction, applicationCursor: Bool) -> String {
        cursorKey(direction == .next ? "C" : "D", applicationCursor: applicationCursor)
    }

    static func cursorKey(_ final: String, applicationCursor: Bool) -> String {
        (applicationCursor ? "\u{1b}O" : "\u{1b}[") + final
    }

    /// bracketed paste の始まりと終わり。
    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    /// 貼り付けと Enter を同時に送ると Enter が貼り付けに飲まれるので、少し空ける。
    public static let submitDelay: TimeInterval = 0.3

    /// 入力欄を消す 1 組（Ctrl-E で行末へ・Ctrl-K で次の改行を消す・Ctrl-U で行頭までか前の改行を消す）。v2.1.309 の入力欄の実装で確認。
    /// Esc と Ctrl-C は作業中だと中断になり、Ctrl-L は画面の消去と同じ処理に割り当てられていて入力欄だけを消すと確かめられないので使わない。空と読めるまで繰り返す。
    public static let clearInputRound: [String] = ["\u{05}", "\u{0B}", "\u{15}"]
    /// 消すキーを 1 つずつ送る間隔（まとめて書くと 1 回の入力として読まれうるため）。
    public static let clearKeyInterval: TimeInterval = 0.03
    /// 1 組を送った後、描き直しを待ってから入力欄を読むまでの間。
    public static let clearCheckDelay: TimeInterval = 0.15
    /// 繰り返す組の上限（行ごとに 2 組ほど要る）。
    public static let clearMaxRounds = 40
    /// 入力欄を読めないまま繰り返す組の上限。
    public static let clearUnreadableRounds = 12
    /// 入力欄の表示が変わらないまま続いたらやめる組の数（消えない薄字の表示を待ち続けないため）。
    public static let clearStallRounds = 3

    /// 入力欄に入れる本文（送るものが無ければ nil）。bracketed paste なら改行を含めたまま 1 回の貼り付けとして届く。
    public static func messageBody(_ text: String, bracketedPaste: Bool) -> String? {
        var body = sanitize(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if bracketedPaste {
            return pasteStart + body + pasteEnd
        }
        // 貼り付けモードでない端末では改行が送信になるので、1 行に畳む。
        return body.split(separator: "\n").map { $0.trimmed }.joined(separator: " ")
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

/// 「端末の画面」から 1 回ずつ直接送れるキー。カードで答えられない時の逃げ道なので、文字の自由入力は持たない。
public enum TerminalKey: Hashable, Sendable {
    case up, down, left, right
    case enter, escape, tab, space
    /// 1〜9 だけ（範囲外は送らない）。
    case digit(Int)
    /// 端末の入力欄を空にする（`PTYInput.clearInputRound` を空になるまで送る。1 回の列ではないので `sequence` は nil）。
    case clearInput

    /// シートに並べる順。
    public static let all: [TerminalKey] = [.left, .up, .down, .right, .enter, .escape, .tab, .space] + (1...9).map { .digit($0) }

    /// PTY に送る列。矢印は実キーボードと同じく端末のカーソルモードに合わせる。送れないキーは nil。
    public func sequence(applicationCursor: Bool) -> String? {
        switch self {
        case .up: return PTYInput.arrowKey(.up, applicationCursor: applicationCursor)
        case .down: return PTYInput.arrowKey(.down, applicationCursor: applicationCursor)
        case .right: return PTYInput.cursorKey("C", applicationCursor: applicationCursor)
        case .left: return PTYInput.cursorKey("D", applicationCursor: applicationCursor)
        case .enter: return PTYInput.submitKey
        case .escape: return "\u{1b}"
        case .tab: return "\t"
        case .space: return " "
        case .digit(let number): return (1...9).contains(number) ? String(number) : nil
        case .clearInput: return nil
        }
    }

    /// ボタンと結果の一言に出す名前。
    public var label: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .enter: return "Enter"
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .space: return "Space"
        case .digit(let number): return String(number)
        case .clearInput: return "入力欄を消す"
        }
    }

    /// ❯ やタブを動かすキー（送った後、反映までカードからの移動を待たせる）。
    public var movesCursor: Bool {
        switch self {
        case .up, .down, .left, .right: return true
        case .enter, .escape, .tab, .space, .digit, .clearInput: return false
        }
    }

    /// キーボードの押下の文字（SwiftUI の `KeyEquivalent.character`）から。矢印は AppKit の機能キーの私用領域（U+F700〜）で届く。
    public init?(keyCharacter: Character) {
        switch keyCharacter {
        case "\u{F700}": self = .up
        case "\u{F701}": self = .down
        case "\u{F702}": self = .left
        case "\u{F703}": self = .right
        // テンキーの Enter は ETX（U+0003）で届く。
        case "\r", "\u{3}": self = .enter
        case "\u{1b}": self = .escape
        case "\t": self = .tab
        case " ": self = .space
        default:
            guard let number = keyCharacter.wholeNumberValue, keyCharacter.isASCII, (1...9).contains(number) else { return nil }
            self = .digit(number)
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

    /// セッションファイルの返事待ちも見る（画面で読めないダイアログにも Enter は取られる）。`screenChangedAt` は最後の出力の時刻。
    public static func detect(screen: [String], waiting: SessionWaiting?, screenChangedAt: Date?) -> InputBlock? {
        if let block = detect(screen: screen) { return block }
        return waiting?.blocksSend(screen: screen, screenChangedAt: screenChangedAt) == true ? .menu : nil
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

/// `~/.claude/sessions/<pid>.json` の返事待ちの状態（status / waitingFor）。
public struct SessionWaiting: Sendable, Equatable {
    public var status: String?
    public var waitingFor: String?
    /// status を書いた時刻（Unix ミリ秒）。
    public var statusUpdatedAt: Double?

    public init(status: String?, waitingFor: String?, statusUpdatedAt: Double? = nil) {
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// ダイアログ系の waitingFor（v2.1.288 のバイナリで確認した値）。権限確認・質問は画面で読むので入れない。
    static let dialogValues: Set<String> = ["dialog open", "sandbox request", "goal proposal"]

    /// ダイアログが開いていて、入力欄への Enter がそちらに取られる状態か。
    public var isDialogOpen: Bool {
        status == "waiting" && waitingFor.map(Self.dialogValues.contains) == true
    }

    /// ダイアログの描画と status の書き込みのずれとして許す幅。
    static let freshMargin: TimeInterval = 1.0

    /// waitingFor は閉じた後も古いまま残りうるので、通常の空の入力欄が見えている時は画面の最後の変化より後に書かれた時だけ信じる。
    public func blocksSend(screen: [String], screenChangedAt: Date?) -> Bool {
        guard isDialogOpen else { return false }
        if !InputBox.isPlainEmpty(screen: screen) { return true }
        guard let statusUpdatedAt, let screenChangedAt else { return false }
        return Date(epochMillis: statusUpdatedAt) >= screenChangedAt.addingTimeInterval(-Self.freshMargin)
    }
}

/// 端末画面に出ている選択メニュー（❯ で選ぶもの）の判定。値は TUI v2.1.286 で確認。
public enum ChoiceMenu {
    /// 見る範囲（末尾の空行を除いた画面の下から）。メニューは常に描画済みの最下部に出る。
    static let tailLines = 30
    /// メニューの操作案内（行頭）。trust 確認のように番号の無いメニューはこれで見分ける。
    static let footerPrefixes = ["enter to confirm", "enter to select", "enter to continue", "esc to cancel", "esc to exit"]
    /// 案内行の「·」区切りの 1 つ（`↑/↓ to navigate`・`Enter to select` 等。キーの名前は ASCII と矢印だけ）。
    static let footerPartPattern = #"^[a-z0-9↑↓←→/+\-]{1,15} to [a-z]"#

    public static func isShowing(screen: [String]) -> Bool {
        var lines = Array(TerminalScreen.droppingTrailingBlankLines(screen).suffix(tailLines)).map { $0.trimmed }
        if overlayRange(lines) != nil { return true }
        // 下部に入力欄があれば、それより上は会話の履歴、欄の中は入力中の文なので見ない。
        if let start = InputBox.zoneStart(lines) {
            lines = Array(lines[start...])
        }
        let footerZone = lines.filter { !$0.isEmpty }.suffix(8)
        if footerZone.contains(where: isFooter) { return true }
        return hasNumberedChoices(lines)
    }

    /// 入力欄の上の罫線から案内行を探す範囲（空行を除いた行数）。
    static let overlayFooterReach = 3

    /// 入力欄の上に重ねて出たメニューの範囲（v2.1.288 の fullscreen では申し出等が入力欄の真上に重なり、❯ と罫線は下に残る）。
    /// 会話の中の案内行風の文字を拾わないよう、案内行が入力欄の罫線に接している時だけとみなす。
    static func overlayRange(_ lines: [String]) -> Range<Int>? {
        guard let prompt = InputBox.promptIndex(lines) else { return nil }
        let rule = prompt - 1
        var index = rule - 1
        var seen = 0
        while index >= 0, seen < overlayFooterReach {
            let line = lines[index]
            if !line.trimmed.isEmpty {
                if PermissionPrompt.isSeparator(line) { return nil }
                if isFooter(line) {
                    // ダイアログは上端を罫線で閉じ、中に会話・ステータス行を挟まない（返答の中の案内行風の文を拾わないため）。
                    guard let top = (0..<index).last(where: { PermissionPrompt.isSeparator(lines[$0]) }),
                          !lines[top..<rule].contains(where: isConversationLine) else { return nil }
                    return top..<rule
                }
                seen += 1
            }
            index -= 1
        }
        return nil
    }

    /// 会話（⏺）かステータス（✻）の行か。
    static func isConversationLine(_ line: String) -> Bool {
        let t = line.trimmed
        return t.hasPrefix("⏺") || t.hasPrefix("✻")
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
        let (rest, hasCursor) = strippingCursor(line)
        guard hasCursor, rest.last == "." else { return nil }
        let digits = rest.dropLast()
        guard (1...2).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// 選択肢の番号。`cursor` なら ❯ の付いた行だけを見る。
    static func choiceNumber(_ line: String, cursor: Bool) -> Int? {
        let (rest, hasCursor) = strippingCursor(line)
        if cursor && !hasCursor { return nil }
        let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.first == ".", after.dropFirst().first?.isWhitespace == true else { return nil }
        return Int(digits)
    }

    /// 前後の空白と行頭の ❯（続く空白も）を外した行と、❯ があったか。
    static func strippingCursor(_ line: String) -> (text: Substring, hasCursor: Bool) {
        let trimmed = Substring(line.trimmed)
        guard trimmed.hasPrefix("❯") else { return (trimmed, false) }
        return (trimmed.dropFirst().drop(while: \.isWhitespace), true)
    }
}

/// 端末の 1 文字の描き方（入力欄の薄字の案内を見分けるため）。
public enum CellTone: Sendable, Equatable {
    case plain
    /// 薄字（SGR 2）。
    case dim
    /// 反転（カーソル）。
    case inverse
}

/// 画面の行（`screen` の添字）から、その行の各文字（`Array(screen[row])` と同じ並び）の描き方を返す。読めなければ nil。
public typealias CellToneReader = (Int) -> [CellTone]?

/// 端末下部の入力欄（罫線の直下の ❯ 行から次の罫線まで）。
public enum InputBox {
    /// 入力欄の ❯ 行。`❯ n. …` は下を罫線で閉じている時だけ入力欄とみなす（v2.1.286 で選択メニューは ❯ の下を閉じない）。
    static func promptIndex(_ lines: [String]) -> Int? {
        lines.indices.last { index in
            guard index > 0 else { return false }
            let line = lines[index].trimmed
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

    /// 入力欄に入っている文字（空なら ""）。入力欄が見つからなければ nil。
    /// 空欄の薄字の案内（例文・キューの案内・次の依頼の候補）は、`tones` で欄の文字がすべて薄字と読めた時だけ空とみなす。
    /// 描き方を読めない時（`tones` が nil）は案内と同じ形でも本文として返す（本文を空と読み違えて二重に貼らないため）。
    public static func text(screen: [String], tones: CellToneReader? = nil) -> String? {
        let lines = TerminalScreen.droppingTrailingBlankLines(screen)
        guard let start = promptIndex(lines) else { return nil }
        let rows = boxRows(lines, start: start)
        let parts = rows.map { content(lines[$0], prompt: $0 == start) }.filter { !$0.isEmpty }
        if !parts.isEmpty, let tones, isFaint(lines, rows: rows, prompt: start, tones: tones) { return "" }
        return parts.joined(separator: "\n")
    }

    /// 入力欄の ❯ 行から下の罫線の手前までの行。
    static func boxRows(_ lines: [String], start: Int) -> [Int] {
        var rows = [start]
        for index in (start + 1)..<max(start + 1, lines.count) {
            if PermissionPrompt.isSeparator(lines[index]) { break }
            rows.append(index)
        }
        return rows
    }

    /// 欄の 1 行の文字（前後の空白と、❯ 行なら先頭の ❯ を除く）。
    static func content(_ line: String, prompt: Bool) -> String {
        var t = Substring(line.trimmed)
        if prompt { t = t.dropFirst().drop(while: \.isWhitespace) }
        return String(t)
    }

    /// 欄の空白以外の文字がすべて薄字か。案内は先頭 1 文字にカーソル（反転）が乗ることがあるので、先頭だけは反転も許す（v2.1.309 の描き方）。
    static func isFaint(_ lines: [String], rows: [Int], prompt: Int, tones: CellToneReader) -> Bool {
        var seen: [CellTone] = []
        for row in rows {
            let characters = Array(lines[row])
            var skippedPrompt = row != prompt
            for (index, character) in characters.enumerated() where !character.isWhitespace {
                if !skippedPrompt, character == "❯" {
                    skippedPrompt = true
                    continue
                }
                guard let rowTones = tones(row), rowTones.indices.contains(index) else { return false }
                seen.append(rowTones[index])
            }
        }
        guard let first = seen.first, first != .plain, seen.contains(.dim) else { return false }
        return seen.dropFirst().allSatisfy { $0 == .dim }
    }

    /// 案内と同じ形の文か（行をつないで見る。折り返して 2 行になることもあるため）。
    static func looksPlaceholder(_ lines: [String]) -> Bool {
        let parts = lines.map { $0.trimmed }.filter { !$0.isEmpty }
        return !parts.isEmpty && parts.count <= 2 && isPlaceholder(parts.joined(separator: " "))
    }

    /// 入力欄の ❯ 行の位置（`screen` の添字）。入力欄が見つからなければ nil。
    public static func promptRow(screen: [String]) -> Int? {
        promptIndex(TerminalScreen.droppingTrailingBlankLines(screen))
    }

    /// 通常の空の入力欄だけが見えているか。入力欄が空で、最後の会話・ステータス行との間に罫線（重ね表示の上端）が無い。
    /// 古い返事待ちを信じるかの目安なので、描き方を読まずに案内と同じ形の文も空とみなす。
    public static func isPlainEmpty(screen: [String]) -> Bool {
        let lines = Array(TerminalScreen.droppingTrailingBlankLines(screen).suffix(ChoiceMenu.tailLines))
        guard let prompt = promptIndex(lines) else { return false }
        let parts = boxRows(lines, start: prompt).map { content(lines[$0], prompt: $0 == prompt) }.filter { !$0.isEmpty }
        guard parts.isEmpty || looksPlaceholder(parts) else { return false }
        let above = lines[..<(prompt - 1)]
        guard let separator = above.lastIndex(where: PermissionPrompt.isSeparator) else { return true }
        return above.lastIndex(where: ChoiceMenu.isConversationLine).map { $0 > separator } ?? false
    }

    /// 空欄の時に薄字で出る案内（v2.1.309 のバイナリで確認）。作業中にキューへ積んだメッセージがあると出る。
    static let placeholderTexts: Set<String> = [
        "Press up to edit queued messages",
        "Press up to select a queued message, then Enter to edit it",
        "Press up to edit queued messages, Enter to send them immediately",
        "Press up to select a queued message to edit, or Enter to send them now",
        "Press Enter to edit the selected message, or up again for history",
        "Press Enter to edit the selected message, or up again for an older one",
    ]

    /// 空欄の時に出る例文（v2.1.286: `Try "fix lint errors"`）と案内（キューの編集・`Message @<エージェント>…`）。
    static func isPlaceholder(_ text: String) -> Bool {
        if text.hasPrefix("Try \"") && text.hasSuffix("\"") && text.count > 6 { return true }
        if placeholderTexts.contains(text) { return true }
        return text.hasPrefix("Message @") && text.hasSuffix("…") && !text.contains("\n")
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

    /// 区切り線（─）から「Do you want to …?」の手前までを本文とし、選択肢（1. Yes …）が続く時だけ読む。
    public static func parse(screen: [String]) -> PermissionPrompt? {
        guard let questionIndex = screen.lastIndex(where: { isQuestion($0) }) else { return nil }
        let after = screen[(questionIndex + 1)...].prefix(6)
        guard after.contains(where: { $0.trimmed.range(of: #"^(❯\s*)?1\.\s*Yes"#, options: .regularExpression) != nil }) else {
            return nil
        }
        var start = questionIndex
        while start > 0, questionIndex - start < 20 {
            let line = screen[start - 1]
            if isSeparator(line) { break }
            start -= 1
        }
        let body = screen[start..<questionIndex]
            .map { $0.trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("Tip:") && !isRule($0, of: "╌") }
        guard let title = body.first else { return PermissionPrompt(title: "権限の確認", lines: []) }
        return PermissionPrompt(title: title, lines: Array(body.dropFirst()))
    }

    static func isQuestion(_ line: String) -> Bool {
        let t = line.trimmed.lowercased()
        return t.hasPrefix("do you want to") && t.hasSuffix("?")
    }

    /// プロンプトの外枠（実線）。コマンドを囲む破線（╌）は枠の内側なので境界にしない。
    static func isSeparator(_ line: String) -> Bool {
        isRule(line, of: "─") || isRule(line, of: "━")
    }

    static func isRule(_ line: String, of character: Character) -> Bool {
        let t = line.trimmed
        return t.count >= 8 && t.allSatisfy { $0 == character }
    }
}

extension StringProtocol {
    /// 前後の空白（改行は含めない）を落とす。
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

/// 端末バッファの読み出しの補助。
public enum TerminalScreen {
    /// 末尾の空行を落とす。端末が縦に長いと TUI は上詰めで描くので、下の空行で見る範囲がずれないようにする。
    public static func droppingTrailingBlankLines(_ screen: [String]) -> [String] {
        var end = screen.count
        while end > 0, screen[end - 1].trimmed.isEmpty { end -= 1 }
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
