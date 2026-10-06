import Foundation

/// 端末画面に出ている選択メニュー（plan の承認・AskUserQuestion・trust 確認など）の中身。
public struct MenuPrompt: Sendable, Hashable {
    public struct Option: Sendable, Hashable {
        /// 「1. …」の番号。trust 確認のように番号の無いメニューでは nil。
        public var number: Int?
        public var label: String
        /// 選択肢の下に字下げで続く説明行。
        public var detail: [String]
        /// 複数選択のチェック欄（`[ ]` / `[✓]` 等）。チェック欄の無い選択肢は nil、あれば付いているか。
        public var checked: Bool?
        /// 複数選択の選択肢の下に出る「Submit」/「Next」の行。番号もチェック欄も無く、Enter で次の問い（最後なら確認）へ進む。
        public var isSubmit: Bool

        public init(number: Int?, label: String, detail: [String] = [], checked: Bool? = nil, isSubmit: Bool = false) {
            self.number = number
            self.label = label
            self.detail = detail
            self.checked = checked
            self.isSubmit = isSubmit
        }

        /// 選ぶと文字の入力に移る選択肢。カードからは本文を渡せないので選ばせない。
        /// 複数選択の自由入力の行は ❯ が乗ると例文が消えてチェック欄だけになる。
        public var isFreeText: Bool {
            if isSubmit { return false }
            if checked != nil && label.isEmpty { return true }
            let lowered = label.lowercased()
            return MenuPrompt.freeTextPrefixes.contains { lowered.hasPrefix($0) }
        }
    }

    /// 問いより上の見出し・本文（plan の中身、trust 確認のフォルダ等）。
    public var context: [String]
    /// 問い（選択肢の直前の行）。読み取れなければ ""。
    public var question: String
    public var options: [Option]
    /// ❯ の付いている選択肢の位置（options の添字）。
    public var cursor: Int
    /// 操作案内の行（`Enter to confirm · Esc to cancel` 等）。無ければ ""。
    public var footer: String
    /// AskUserQuestion の問いのタブ（`← ☒ 見出し  ✔ Submit →`）。無ければ nil。
    public var tabs: MenuTabs?

    public init(context: [String], question: String, options: [Option], cursor: Int, footer: String = "", tabs: MenuTabs? = nil) {
        self.context = context
        self.question = question
        self.options = options
        self.cursor = cursor
        self.footer = footer
        self.tabs = tabs
    }

    /// AskUserQuestion の最後の確認（Submit タブ）の画面か。
    public var isReview: Bool { tabs?.isOnSubmit == true }

    /// 複数選択（チェック欄付き）のメニューか。Enter は確定ではなくチェックの切り替えになる。
    public var isMultiSelect: Bool { options.contains { $0.checked != nil } }

    /// Esc が claude の終了になるメニュー（案内が「Esc to exit」か、フォルダの trust 確認）。
    public var cancelExits: Bool {
        ChoiceMenu.footerExits(footer) || options.contains { $0.label.lowercased().hasPrefix("yes, i trust this folder") }
    }

    /// AskUserQuestion の「Type something.」・plan の「Tell Claude what to change」（v2.1.286）。
    static let freeTextPrefixes = ["type something", "tell claude what to change"]

    /// カーソル位置を除いて同じメニューか（押した時のカードと今の画面の照合に使う）。
    /// 今のタブは文字ではなく背景色で読むので比べない（問いの文面でタブの違いは分かる）。
    public func sameMenu(as other: MenuPrompt) -> Bool {
        context == other.context && question == other.question && options == other.options
            && tabs?.ignoringCurrent == other.tabs?.ignoringCurrent
    }

    /// 同じ問いの画面か（チェック・❯ の位置は見ない）。タブを移ったかの判定に使う。
    public func samePage(as other: MenuPrompt) -> Bool {
        context == other.context && question == other.question && options.map(\.label) == other.options.map(\.label)
            && tabs?.current == other.tabs?.current
    }

    /// カーソル位置を除いた中身の識別子（中身が替わったカードを作り直すのに使う）。
    public var identity: Int {
        var hasher = Hasher()
        hasher.combine(context)
        hasher.combine(question)
        hasher.combine(options)
        hasher.combine(footer)
        hasher.combine(tabs)
        return hasher.finalize()
    }
}

/// AskUserQuestion の上部のタブ行。v2.1.286 の描画は `← ☒ 見出し … ✔ Submit →`（☒ 回答済み・☐ 未回答）で、今のタブは背景色だけで示す。
/// 問いが 1 つの単一選択は Submit タブも矢印も無く ` ☐ 見出し ` だけ。
public struct MenuTabs: Sendable, Hashable {
    public struct Tab: Sendable, Hashable {
        public var title: String
        public var answered: Bool

        public init(title: String, answered: Bool) {
            self.title = title
            self.answered = answered
        }
    }

    public var tabs: [Tab]
    public var hasSubmit: Bool
    /// ← / → で移れるか（矢印が出ているか）。
    public var hasArrows: Bool
    /// 今のタブ（tabs の添字。tabs.count は Submit タブ）。読めなければ nil。
    public var current: Int?

    public init(tabs: [Tab], hasSubmit: Bool, hasArrows: Bool, current: Int? = nil) {
        self.tabs = tabs
        self.hasSubmit = hasSubmit
        self.hasArrows = hasArrows
        self.current = current
    }

    public var isOnSubmit: Bool { hasSubmit && current == tabs.count }
    /// → で次へ移れるか（今のタブが読めなければ移れるものとして送り、画面で確かめる）。
    public var canMoveNext: Bool {
        guard hasArrows else { return false }
        guard let current else { return true }
        return current < tabs.count - (hasSubmit ? 0 : 1)
    }
    public var canMovePrevious: Bool {
        guard hasArrows else { return false }
        guard let current else { return true }
        return current > 0
    }

    var ignoringCurrent: MenuTabs {
        var copy = self
        copy.current = nil
        return copy
    }

    static let marks: [Character: Bool?] = ["☐": false, "☒": true, "✔": nil]

    /// タブ行を読む。各タブの文字の範囲（行の Character の位置。最後が Submit）も返す。タブ行でなければ nil。
    static func parse(_ line: String) -> (MenuTabs, [Range<Int>])? {
        let characters = Array(line)
        var start = characters.firstIndex { !$0.isWhitespace } ?? characters.count
        var end = (characters.lastIndex { !$0.isWhitespace } ?? -1) + 1
        guard start < end else { return nil }
        let hasArrows = characters[start] == "←" && characters[end - 1] == "→" && end - start > 2
        if hasArrows {
            start += 1
            end -= 1
        }
        var items: [(mark: Character, range: Range<Int>)] = []
        for index in start..<end where marks[characters[index]] != nil {
            guard index == start || characters[index - 1].isWhitespace else { continue }
            if let last = items.popLast() { items.append((last.mark, last.range.lowerBound..<index)) }
            items.append((characters[index], index..<end))
        }
        guard let first = items.first, first.range.lowerBound == (characters[start...].firstIndex { !$0.isWhitespace } ?? end) else { return nil }
        var tabs: [Tab] = []
        var ranges: [Range<Int>] = []
        var hasSubmit = false
        for (offset, item) in items.enumerated() {
            let text = String(characters[(item.range.lowerBound + 1)..<item.range.upperBound]).trimmingCharacters(in: .whitespaces)
            var upper = item.range.upperBound
            while upper > item.range.lowerBound + 1, characters[upper - 1].isWhitespace { upper -= 1 }
            let range = item.range.lowerBound..<upper
            guard let answered = marks[item.mark] ?? nil else {
                // ✔ は最後の Submit タブだけ。
                guard offset == items.count - 1, text == "Submit", !tabs.isEmpty else { return nil }
                hasSubmit = true
                ranges.append(range)
                continue
            }
            guard !text.isEmpty else { return nil }
            tabs.append(Tab(title: text, answered: answered))
            ranges.append(range)
        }
        guard !tabs.isEmpty else { return nil }
        // 矢印が無いのは問いが 1 つの単一選択だけ（Submit タブも無い）。
        if !hasArrows, tabs.count != 1 || hasSubmit { return nil }
        return (MenuTabs(tabs: tabs, hasSubmit: hasSubmit, hasArrows: hasArrows), ranges)
    }
}

extension ChoiceMenu {
    /// ❯ の行を探すのは操作案内（無ければ画面の末尾）からこの行数まで。上の会話履歴の ❯ を選択肢と読まないため。
    static let cursorSearchLines = 24

    /// 画面の選択メニューを読み取る。メニューが無い・形が読めない時は nil。
    /// `highlight` は画面の行（`screen` の添字）の各文字に背景色が付いているか。タブ行の今のタブを見分けるのに使う。
    public static func parse(screen: [String], highlight: ((Int) -> [Bool]?)? = nil) -> MenuPrompt? {
        guard isShowing(screen: screen) else { return nil }
        return parseShowing(screen: screen, highlight: highlight)
    }

    /// `isShowing` を確かめ済みの画面から読み取る。
    public static func parseShowing(screen: [String], highlight: ((Int) -> [Bool]?)? = nil) -> MenuPrompt? {
        let (lines, offset, overlay) = menuZoneWithOffset(screen)
        let footerRow = footerIndex(lines)
        guard let cursorRow = cursorIndex(lines, footerRow: footerRow) else { return nil }

        let rows: [(index: Int, option: MenuPrompt.Option)]
        if choiceNumber(lines[cursorRow], cursor: true) != nil {
            rows = numberedRows(lines, anchorRow: cursorRow)
        } else if overlay {
            // 重ね表示はウィザード（左右で値を変える・チェック欄）もあり、番号の無い行を選択肢と読むと押し方が違うので Esc だけにする。
            return nil
        } else if isSubmitButton(lines[cursorRow]),
                  let anchor = (0..<cursorRow).last(where: { choiceNumber(lines[$0], cursor: false) != nil }) {
            // ❯ が複数選択の Submit 行にある時は、すぐ上の選択肢から番号の列を読む。
            rows = numberedRows(lines, anchorRow: anchor)
        } else {
            // 番号の無い ❯ 行は会話履歴の発話と見分けにくいので、操作案内が出ている時だけ選択肢とみなす。
            guard footerRow != nil else { return nil }
            rows = plainRows(lines, cursorRow: cursorRow)
        }
        guard rows.count >= 2, let first = rows.first, let cursor = rows.firstIndex(where: { $0.index == cursorRow }) else { return nil }
        let (question, questionRow) = questionAbove(lines, before: first.index)
        let top = questionRow ?? first.index
        let footer = footerRow.map { lines[$0].trimmingCharacters(in: .whitespaces) } ?? ""
        let context: [String]
        var tabs: MenuTabs?
        if let (tabRow, parsed, ranges) = tabRow(lines, above: top, question: question) {
            // タブ行より上は会話の履歴なので、本文はタブ行と問いの間だけ。
            context = Array(lines[(tabRow + 1)..<top].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(12))
            tabs = parsed
            if parsed.hasSubmit, question == reviewQuestion || context.contains(reviewTitle) {
                tabs?.current = parsed.tabs.count
            } else if let flags = highlight?(tabRow + offset) {
                tabs?.current = ranges.firstIndex { range in range.contains { $0 < flags.count && flags[$0] } }
            }
        } else {
            context = contextAbove(lines, before: top)
        }
        return MenuPrompt(context: context, question: question, options: rows.map(\.option), cursor: cursor, footer: footer, tabs: tabs)
    }

    /// Submit タブ（回答の確認）の見出しと問い（v2.1.286）。
    static let reviewTitle = "Review your answers"
    static let reviewQuestion = "Ready to submit your answers?"

    /// 問い（無ければ選択肢）の上にあるタブ行の位置と中身。罫線・会話の行に当たるまでに無ければ nil。
    /// 問いの画面ではすぐ上、確認画面では間に見出しと回答の一覧が入る。
    static func tabRow(_ lines: [String], above row: Int, question: String) -> (Int, MenuTabs, [Range<Int>])? {
        var index = row - 1
        var scanned = 0
        while index >= 0, scanned < contextScanLines {
            let line = lines[index]
            if PermissionPrompt.isSeparator(line) || isHistoryOrProgress(line) { return nil }
            if let (tabs, ranges) = MenuTabs.parse(line) { return (index, tabs, ranges) }
            // 本文の「☐ …」をタブと読まないよう、確認画面以外はすぐ上の行だけを見る。
            if question != reviewQuestion, !line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            index -= 1
            scanned += 1
        }
        return nil
    }

    /// 複数選択の選択肢の下の「Submit」（最後の問い）/「Next」の行。
    static func isSubmitButton(_ line: String) -> Bool {
        submitLabel(line) != nil
    }

    static func submitLabel(_ line: String) -> String? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("❯") { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        return submitLabels.contains(String(rest)) ? String(rest) : nil
    }

    static let submitLabels: Set<String> = ["Submit", "Next"]

    /// メニューを探す範囲（画面の下部。入力欄の上に重なったメニューがあればそこ、無ければ入力欄の下だけ）。
    static func menuZone(_ screen: [String]) -> [String] {
        menuZoneWithOffset(screen).lines
    }

    /// メニューを探す範囲と、その先頭が `screen` の何行目か、入力欄の上に重なったメニューか。
    static func menuZoneWithOffset(_ screen: [String]) -> (lines: [String], offset: Int, overlay: Bool) {
        let trimmed = TerminalScreen.droppingTrailingBlankLines(screen)
        var offset = max(0, trimmed.count - tailLines)
        var lines = Array(trimmed[offset...])
        if let range = overlayRange(lines) {
            return (Array(lines[range]), offset + range.lowerBound, true)
        }
        if let start = InputBox.zoneStart(lines) {
            lines = Array(lines[start...])
            offset += start
        }
        return (lines, offset, false)
    }

    static func footerIndex(_ lines: [String]) -> Int? {
        lines.lastIndex { isFooter($0) }
    }

    /// 操作案内の行か。行頭が案内の文言か、「·」で区切った各部分がキーの案内で `Enter to …` と `Esc to …` を含む行。
    static func isFooter(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        if footerPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        let parts = lowered.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2,
              parts.allSatisfy({ $0.range(of: footerPartPattern, options: .regularExpression) != nil }) else { return false }
        return parts.contains { $0.hasPrefix("enter to ") } && parts.contains { $0.hasPrefix("esc to ") }
    }

    /// 案内行が「Esc to exit」（Esc で claude が終わる）か。
    public static func footerExits(_ footer: String) -> Bool {
        footer.lowercased().contains("esc to exit")
    }

    /// 案内行（無ければ末尾）から上へ限られた行数だけ ❯ の行を探す。会話の返答（⏺）に当たればそこで止める。
    static func cursorIndex(_ lines: [String], footerRow: Int?) -> Int? {
        var index = (footerRow ?? lines.count) - 1
        var scanned = 0
        while index >= 0, scanned < cursorSearchLines {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("⏺") { return nil }
            if trimmed.hasPrefix("❯") { return index }
            index -= 1
            scanned += 1
        }
        return nil
    }

    /// 選択肢が出ているのに中身を読めない時、そのメニューを見分ける写し（押した時と今が同じかの照合に使う）。
    /// 選択肢として読める・メニューが無い時は nil。
    public static func unreadable(screen: [String]) -> UnreadableMenu? {
        guard isShowing(screen: screen), parseShowing(screen: screen) == nil else { return nil }
        let lines = menuZone(screen).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let footer = footerIndex(lines).map { lines[$0] } ?? ""
        let exits = footerExits(footer) || lines.contains { $0.lowercased().contains("trust this folder") }
        return UnreadableMenu(lines: Array(lines.suffix(12)), cancelExits: exits)
    }

    /// 画面で読めない選択メニューか、画面に出ていないがセッションファイルがダイアログを示す時の写し。
    public static func unreadable(screen: [String], waiting: SessionWaiting?) -> UnreadableMenu? {
        guard PermissionPrompt.parse(screen: screen) == nil else { return nil }
        if isShowing(screen: screen) { return unreadable(screen: screen) }
        guard let waiting, waiting.isDialogOpen else { return nil }
        return UnreadableMenu(lines: ["端末でダイアログが開いています（\(waiting.waitingFor ?? "")）"], cancelExits: false, isDialog: true)
    }

    /// 番号付きの選択肢。`anchorRow` の行から番号が 1 ずつ続く範囲だけを取る（上の本文の番号付きリストを混ぜないため）。
    /// 複数選択の最後のチェック欄の下に Submit / Next の行があれば、その位置に選択肢として入れる。
    static func numberedRows(_ lines: [String], anchorRow: Int) -> [(index: Int, option: MenuPrompt.Option)] {
        let numbered = lines.indices.compactMap { index in choiceNumber(lines[index], cursor: false).map { (index, $0) } }
        guard let at = numbered.firstIndex(where: { $0.0 == anchorRow }) else { return [] }
        var lower = at
        while lower > 0, numbered[lower - 1].1 == numbered[lower].1 - 1 { lower -= 1 }
        var upper = at
        while upper + 1 < numbered.count, numbered[upper + 1].1 == numbered[upper].1 + 1 { upper += 1 }
        let run = Array(numbered[lower...upper])
        let lastChecked = run.lastIndex { checkbox(in: label(afterNumberIn: lines[$0.0])).1 != nil }
        var result: [(index: Int, option: MenuPrompt.Option)] = []
        for (offset, entry) in run.enumerated() {
            let (index, number) = entry
            let indent = numberColumn(lines[index])
            let end = offset + 1 < run.count ? run[offset + 1].0 : lines.count
            var detail: [String] = []
            var submit: (row: Int, label: String)?
            for row in (index + 1)..<end {
                let line = lines[row]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || PermissionPrompt.isSeparator(line) { continue }
                if offset == lastChecked, let label = submitLabel(line) {
                    submit = (row, label)
                    break
                }
                // 字下げが選択肢より浅い行は操作案内などの外の行。
                guard leadingWidth(line) > indent else {
                    if offset + 1 == run.count { break }
                    continue
                }
                detail.append(trimmed)
            }
            let (text, checked) = checkbox(in: label(afterNumberIn: lines[index]))
            result.append((index, MenuPrompt.Option(number: number, label: text, detail: detail, checked: checked)))
            if let submit {
                result.append((submit.row, MenuPrompt.Option(number: nil, label: submit.label, isSubmit: true)))
            }
        }
        return result
    }

    /// 番号の無い選択肢（trust 確認）。❯ の行と、空行を挟まずに同じ字下げで並ぶ行。
    static func plainRows(_ lines: [String], cursorRow: Int) -> [(index: Int, option: MenuPrompt.Option)] {
        let cursorLine = Substring(lines[cursorRow].trimmingCharacters(in: .whitespaces)).dropFirst()
        let column = lines[cursorRow].prefix(while: \.isWhitespace).count + 1 + cursorLine.prefix(while: \.isWhitespace).count
        func isSibling(_ index: Int) -> Bool {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("❯") && leadingWidth(line) == column && !PermissionPrompt.isSeparator(line)
        }
        var start = cursorRow
        while start > 0, isSibling(start - 1) { start -= 1 }
        var end = cursorRow
        while end + 1 < lines.count, isSibling(end + 1) { end += 1 }
        return (start...end).map { index in
            var text = Substring(lines[index].trimmingCharacters(in: .whitespaces))
            if text.hasPrefix("❯") { text = text.dropFirst() }
            return (index, MenuPrompt.Option(number: nil, label: text.trimmingCharacters(in: .whitespaces)))
        }
    }

    /// 選択肢の直前（空行は飛ばす）の行。罫線に当たれば問いは無い。
    /// 80 桁を超える・改行のある問いは左の縦線（`│ `）付きで折り返して出るので、続く縦線の行をまとめて 1 つの問いにする。
    static func questionAbove(_ lines: [String], before row: Int) -> (String, Int?) {
        var index = row - 1
        while index >= 0 {
            let line = lines[index]
            if PermissionPrompt.isSeparator(line) { return ("", nil) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(gutter) {
                var top = index
                while top > 0, lines[top - 1].trimmingCharacters(in: .whitespaces).hasPrefix(gutter) { top -= 1 }
                let parts = lines[top...index].map { $0.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces) }
                return (joinWrapped(parts), top)
            }
            if !trimmed.isEmpty { return (trimmed, index) }
            index -= 1
        }
        return ("", nil)
    }

    /// 折り返した問いの左の縦線（Ink の borderLeft・single）。
    static let gutter = "│"

    /// 折り返した行をつなぐ。英数字は空白の所で折り返されて空白が消えるので戻し、和文はそのままつなぐ。
    static func joinWrapped(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first, last.isASCII, !last.isWhitespace, isWordCharacter(first),
               isWordCharacter(last) || ",.;:!?)".contains(last) {
                result += " "
            }
            result += part
        }
        return result
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// 問いの上の本文。上の罫線までを囲みとし（すぐ上が罫線の plan の承認はその上の囲み）、
    /// 罫線が見当たらなければ空行・会話の行・経過表示で止める（照合に使うので変化する行を入れない）。
    static func contextAbove(_ lines: [String], before row: Int) -> [String] {
        var end = row - 1
        while end >= 0, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        if end >= 0, PermissionPrompt.isSeparator(lines[end]) { end -= 1 }
        guard end >= 0 else { return [] }
        var top = end
        var bounded = false
        while top >= 0, end - top < contextScanLines {
            let line = lines[top]
            if PermissionPrompt.isSeparator(line) { bounded = true; break }
            if isHistoryOrProgress(line) { break }
            top -= 1
        }
        guard top < end else { return [] }
        var collected: [String] = []
        for line in lines[(top + 1)...end].reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if bounded { continue }
                break
            }
            collected.append(trimmed)
        }
        return Array(collected.prefix(12).reversed())
    }

    /// 本文の上端を探す行数。
    static let contextScanLines = 24

    /// 会話の履歴（返答の ⏺・過去の発話の ❯）や経過表示（`✻ Thinking… (3s)` 等）の行。
    static func isHistoryOrProgress(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if first == "⏺" || first == "❯" { return true }
        return "✻✽✶✳✢✺·*".contains(first) && trimmed.contains("…")
    }

    /// 行頭のチェック欄（`[ ]` / `[✓]` / `[x]` / `☐` / `☒` / `☑`）を外し、付いているかを返す。無ければ checked は nil。
    static func checkbox(in label: String) -> (String, Bool?) {
        let marks: [(String, Bool)] = [("[ ]", false), ("[✓]", true), ("[✔]", true), ("[x]", true), ("[X]", true),
                                       ("☐", false), ("☒", true), ("☑", true)]
        for (mark, checked) in marks where label.hasPrefix(mark) {
            let rest = label.dropFirst(mark.count)
            guard rest.isEmpty || rest.first?.isWhitespace == true else { continue }
            return (rest.trimmingCharacters(in: .whitespaces), checked)
        }
        return (label, nil)
    }

    static func label(afterNumberIn line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("❯") { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        rest = rest.drop(while: \.isNumber)
        if rest.first == "." { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// 番号の桁の位置（❯ の付いた行も付かない行と同じ桁に揃う）。
    static func numberColumn(_ line: String) -> Int {
        var column = 0
        for character in line {
            if character.isWhitespace || character == "❯" { column += 1 } else { break }
        }
        return column
    }

    static func leadingWidth(_ line: String) -> Int {
        line.prefix(while: \.isWhitespace).count
    }
}

/// 中身を読み取れない選択メニューの写し。
public struct UnreadableMenu: Sendable, Hashable {
    /// メニューの範囲の空でない行（下から最大 12 行）。
    public var lines: [String]
    /// Esc が claude の終了になるか。
    public var cancelExits: Bool
    /// 画面ではなくセッションファイル（waitingFor）でダイアログを知った。
    public var isDialog: Bool

    public init(lines: [String], cancelExits: Bool, isDialog: Bool = false) {
        self.lines = lines
        self.cancelExits = cancelExits
        self.isDialog = isDialog
    }
}

/// 押した選択肢まで ❯ を矢印で 1 行ずつ動かし、着いた位置が続けて変わらない時だけ Enter で確定する。
/// 番号キーは使わない（trust 確認には番号が無く、番号キーが移動か即決定かもメニューで違う）。未反映の矢印は常に 0 か 1 個（`PendingArrowHold`）。
public struct MenuNavigator: Sendable {
    public enum Direction: Sendable, Equatable { case up, down }

    public enum Failure: Sendable, Equatable {
        /// 押した時にメニューが出ていない（既に答え終わった等）。
        case gone
        /// 動かしている途中でメニューが読めなくなったまま戻らない。
        case vanished
        /// 押した時のカードと別のメニューになった。
        case changed
        /// 矢印キーを送っても ❯ が動かない・送っていない動きをした・目的の行に着かない。
        case stuck
    }

    public enum Action: Sendable, Equatable {
        /// 画面の書き換えを待つ。
        case wait
        case press(Direction)
        /// ❯ が目的の行で止まっていて、メニューも押した時と同じ。Enter を送ってよい。
        case confirm
        case abort(Failure)
    }

    /// 矢印の反映を待つ回数の上限。過ぎても再送しない（再送すると未反映のキーが 2 つになり行き過ぎるため）。
    public static let maxWaitsPerPress = 10

    public let expected: MenuPrompt
    public let target: Int
    private var started = false
    private var budget: Int
    private var missing = 0
    /// 最後に読めた ❯ の位置。
    public private(set) var lastCursor = 0
    /// 送った矢印がまだ画面に反映されていない。中止した時に残っていれば、後から ❯ が動きうる。
    public private(set) var hasPendingKey = false
    private var lastDirection: Direction = .down
    private var waited = 0
    /// 目的の行に着いた後、もう一度読んでも動いていないかを確かめている。
    private var settling = false

    /// 押せない選択肢（範囲外・自由入力）なら nil。
    public init?(expected: MenuPrompt, target: Int) {
        guard expected.options.indices.contains(target), !expected.options[target].isFreeText else { return nil }
        self.expected = expected
        self.target = target
        self.budget = expected.options.count * (Self.maxWaitsPerPress + 2) + 12
    }

    /// 今の画面のメニュー（読めなければ nil）を受けて次の一手を返す。
    public mutating func next(_ current: MenuPrompt?) -> Action {
        budget -= 1
        guard budget >= 0 else { return .abort(.stuck) }
        guard let current else {
            // 最初に読めなければ消えている。動かしている途中は描き替えの合間かもしれないので少し待つ。
            missing += 1
            settling = false
            if !started { return .abort(.gone) }
            return missing > 5 ? .abort(.vanished) : .wait
        }
        missing = 0
        if !started {
            guard current.sameMenu(as: expected) else { return .abort(.changed) }
            started = true
            lastCursor = current.cursor
        }
        // 移動中は ❯ の行の描き方が変わりうるので、問い・本文・選択肢の数だけで同じメニューかを見る。
        guard current.question == expected.question, current.context == expected.context,
              current.options.count == expected.options.count else {
            lastCursor = current.cursor
            return .abort(.changed)
        }
        if current.cursor != lastCursor {
            let step = current.cursor - lastCursor
            let accepted = hasPendingKey && step == (lastDirection == .down ? 1 : -1)
            lastCursor = current.cursor
            settling = false
            // 送っていない動き・2 行以上の動きは数えていない入力がある証拠なので、どこで止まるか分からない。
            guard accepted else { return .abort(.stuck) }
            hasPendingKey = false
        }
        if hasPendingKey {
            waited += 1
            return waited > Self.maxWaitsPerPress ? .abort(.stuck) : .wait
        }
        if current.cursor == target {
            guard current.sameMenu(as: expected) else { return .abort(.changed) }
            if settling { return .confirm }
            settling = true
            return .wait
        }
        settling = false
        hasPendingKey = true
        waited = 0
        lastDirection = current.cursor < target ? .down : .up
        return .press(lastDirection)
    }
}

/// 未反映の矢印を残して移動をやめた後、次の移動を始めさせない印。
/// 残ったキーが次の移動の 1 歩と数えられると、着いたと見なした後にもう 1 行動いて別の選択肢で確定してしまうため。
public struct PendingArrowHold: Sendable, Equatable {
    /// 端末の出力がこれだけ止まっていれば、残ったキーは処理済み（か捨てられた）とみなす。
    public static let quietInterval: TimeInterval = 1.5
    /// メニューの描き替えで出力が止まらなくても、claude が入力を読んでいる間にこれだけ経てば外す。
    public static let maxHold: TimeInterval = 5

    public let since: Date
    /// 中止した時に見えていた ❯ の位置。
    public let cursor: Int?

    public init(since: Date, cursor: Int?) {
        self.since = since
        self.cursor = cursor
    }

    /// 中止した移動に未反映の矢印が残っていれば印を作る。
    public static func after(_ navigator: MenuNavigator, now: Date) -> PendingArrowHold? {
        navigator.hasPendingKey ? PendingArrowHold(since: now, cursor: navigator.lastCursor) : nil
    }

    /// 印を外してよいか。❯ が動いた（残りのキーが反映された）・出力が止まった・上限を過ぎた時。
    public func isReleased(now: Date, lastOutput: Date, currentCursor: Int?) -> Bool {
        if let cursor, let currentCursor, currentCursor != cursor { return true }
        if now.timeIntervalSince(max(since, lastOutput)) >= Self.quietInterval { return true }
        return now.timeIntervalSince(since) >= Self.maxHold
    }
}

extension PendingArrowHold {
    /// タブの移動をやめた時に →/← が未反映で残っていれば印を作る（❯ は動かないので時間だけで外す）。
    public static func after(_ mover: MenuTabMover, now: Date) -> PendingArrowHold? {
        mover.hasPendingKey ? PendingArrowHold(since: now, cursor: nil) : nil
    }
}

/// AskUserQuestion の問いのタブを →/← で 1 つ移る手順。キーは 1 回だけ送り、画面の問いが替わったのを確かめて終える。
/// 反映を待ち切れなくても再送しない（2 つ届くと 2 つ先へ移るため）。
public struct MenuTabMover: Sendable {
    public enum Direction: Sendable, Equatable { case next, previous }

    public enum Action: Sendable, Equatable {
        case wait
        case press(Direction)
        /// 別の問い（か確認画面）に替わった。
        case moved
        case abort(MenuNavigator.Failure)
    }

    /// 送ってから画面が替わるのを待つ回数の上限。
    public static let maxWaits = 15

    public let expected: MenuPrompt
    public let direction: Direction
    private var pressed = false
    private var waited = 0
    private var missing = 0
    /// 送った矢印がまだ画面に反映されていない。
    public private(set) var hasPendingKey = false

    /// タブが無い・その向きへ移れない・❯ が自由入力の行にある（→/← が文字入力の操作になる）なら nil。
    public init?(expected: MenuPrompt, direction: Direction) {
        guard let tabs = expected.tabs, direction == .next ? tabs.canMoveNext : tabs.canMovePrevious,
              expected.options.indices.contains(expected.cursor), !expected.options[expected.cursor].isFreeText else { return nil }
        self.expected = expected
        self.direction = direction
    }

    public mutating func next(_ current: MenuPrompt?) -> Action {
        guard pressed else {
            guard let current else { return .abort(.gone) }
            guard current.sameMenu(as: expected), current.options.indices.contains(current.cursor),
                  !current.options[current.cursor].isFreeText else { return .abort(.changed) }
            pressed = true
            hasPendingKey = true
            return .press(direction)
        }
        guard let current else {
            // 問いを描き替える合間は読めないことがある。
            missing += 1
            return missing > 10 ? .abort(.vanished) : .wait
        }
        missing = 0
        if !current.samePage(as: expected) {
            hasPendingKey = false
            return .moved
        }
        waited += 1
        return waited > Self.maxWaits ? .abort(.stuck) : .wait
    }
}
