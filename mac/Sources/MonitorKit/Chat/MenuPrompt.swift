import Foundation

/// 端末画面に出ている選択メニュー（plan の承認・AskUserQuestion・trust 確認など）の中身。
public struct MenuPrompt: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        /// 「1. …」の番号。trust 確認のように番号の無いメニューでは nil。
        public var number: Int?
        public var label: String
        /// 選択肢の下に字下げで続く説明行。
        public var detail: [String]

        public init(number: Int?, label: String, detail: [String] = []) {
            self.number = number
            self.label = label
            self.detail = detail
        }

        /// 選ぶと文字の入力に移る選択肢。カードからは本文を渡せないので選ばせない。
        public var isFreeText: Bool {
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

    public init(context: [String], question: String, options: [Option], cursor: Int) {
        self.context = context
        self.question = question
        self.options = options
        self.cursor = cursor
    }

    /// AskUserQuestion の「Type something.」・plan の「Tell Claude what to change」（v2.1.286）。
    static let freeTextPrefixes = ["type something", "tell claude what to change"]

    /// カーソル位置を除いて同じメニューか（押した時のカードと今の画面の照合に使う）。
    public func sameMenu(as other: MenuPrompt) -> Bool {
        context == other.context && question == other.question && options == other.options
    }
}

extension ChoiceMenu {
    /// 画面の選択メニューを読み取る。メニューが無い・形が読めない時は nil。
    public static func parse(screen: [String]) -> MenuPrompt? {
        guard isShowing(screen: screen) else { return nil }
        var lines = Array(TerminalScreen.droppingTrailingBlankLines(screen).suffix(tailLines))
        if let box = InputBox.promptIndex(lines) { lines = Array(lines[(box + 1)...]) }
        guard let cursorRow = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) else { return nil }

        let rows: [(index: Int, option: MenuPrompt.Option)]
        if choiceNumber(lines[cursorRow], cursor: true) != nil {
            rows = numberedRows(lines, cursorRow: cursorRow)
        } else {
            rows = plainRows(lines, cursorRow: cursorRow)
        }
        guard rows.count >= 2, let first = rows.first, let cursor = rows.firstIndex(where: { $0.index == cursorRow }) else { return nil }
        let (question, questionRow) = questionAbove(lines, before: first.index)
        let context = contextAbove(lines, before: questionRow ?? first.index)
        return MenuPrompt(context: context, question: question, options: rows.map(\.option), cursor: cursor)
    }

    /// 番号付きの選択肢。❯ の行から番号が 1 ずつ続く範囲だけを取る（上の本文の番号付きリストを混ぜないため）。
    static func numberedRows(_ lines: [String], cursorRow: Int) -> [(index: Int, option: MenuPrompt.Option)] {
        let numbered = lines.indices.compactMap { index in choiceNumber(lines[index], cursor: false).map { (index, $0) } }
        guard let at = numbered.firstIndex(where: { $0.0 == cursorRow }) else { return [] }
        var lower = at
        while lower > 0, numbered[lower - 1].1 == numbered[lower].1 - 1 { lower -= 1 }
        var upper = at
        while upper + 1 < numbered.count, numbered[upper + 1].1 == numbered[upper].1 + 1 { upper += 1 }
        let run = Array(numbered[lower...upper])
        return run.enumerated().map { offset, entry in
            let (index, number) = entry
            let indent = numberColumn(lines[index])
            let end = offset + 1 < run.count ? run[offset + 1].0 : lines.count
            var detail: [String] = []
            for line in lines[(index + 1)..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || PermissionPrompt.isSeparator(line) { continue }
                // 字下げが選択肢より浅い行は操作案内などの外の行。
                guard leadingWidth(line) > indent else {
                    if offset + 1 == run.count { break }
                    continue
                }
                detail.append(trimmed)
            }
            return (index, MenuPrompt.Option(number: number, label: label(afterNumberIn: lines[index]), detail: detail))
        }
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
    static func questionAbove(_ lines: [String], before row: Int) -> (String, Int?) {
        var index = row - 1
        while index >= 0 {
            let line = lines[index]
            if PermissionPrompt.isSeparator(line) { return ("", nil) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return (trimmed, index) }
            index -= 1
        }
        return ("", nil)
    }

    /// 問いの上の本文。すぐ上が罫線なら（plan の承認）、その罫線の上の囲みを本文とする。
    static func contextAbove(_ lines: [String], before row: Int) -> [String] {
        var collected: [String] = []
        var crossedRule = false
        var index = row - 1
        while index >= 0, collected.count < 12 {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if PermissionPrompt.isSeparator(line) {
                guard collected.isEmpty, !crossedRule else { break }
                crossedRule = true
            } else if !trimmed.isEmpty {
                // 入力欄の上の過去の発話（❯ …）は本文に入れない。
                if trimmed.hasPrefix("❯") { break }
                collected.append(trimmed)
            }
            index -= 1
        }
        return collected.reversed()
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

/// カードで押した選択肢まで ❯ を矢印キーで動かし、着いたら Enter で確定する手順。
/// 番号キーは使わない（trust 確認には番号が無く、番号キーが「移動」か「即決定」かもメニューごとに違うため）。
public struct MenuNavigator: Sendable {
    public enum Direction: Sendable, Equatable { case up, down }

    public enum Failure: Sendable, Equatable {
        /// メニューが消えた（既に答え終わった等）。
        case gone
        /// 押した時のカードと別のメニューになった。
        case changed
        /// 矢印キーを送っても ❯ が目的の行に着かない。
        case stuck
    }

    public enum Action: Sendable, Equatable {
        /// 画面の書き換えを待つ。
        case wait
        case press(Direction)
        /// ❯ が目的の行にあり、メニューも押した時と同じ。Enter を送ってよい。
        case confirm
        case abort(Failure)
    }

    public let expected: MenuPrompt
    public let target: Int
    private var started = false
    private var budget: Int
    private var missing = 0
    /// 直前に矢印を送った時の ❯ の位置。画面が追いつくまで次を送らない（送りすぎて行き過ぎないため）。
    private var pressedFrom: Int?
    private var waited = 0

    /// 押せない選択肢（範囲外・自由入力）なら nil。
    public init?(expected: MenuPrompt, target: Int) {
        guard expected.options.indices.contains(target), !expected.options[target].isFreeText else { return nil }
        self.expected = expected
        self.target = target
        self.budget = expected.options.count * 6 + 12
    }

    /// 今の画面のメニュー（読めなければ nil）を受けて次の一手を返す。
    public mutating func next(_ current: MenuPrompt?) -> Action {
        budget -= 1
        guard budget >= 0 else { return .abort(.stuck) }
        guard let current else {
            // 最初に読めなければ消えている。動かしている途中は描き替えの合間かもしれないので少し待つ。
            missing += 1
            return !started || missing > 5 ? .abort(.gone) : .wait
        }
        missing = 0
        if !started {
            guard current.sameMenu(as: expected) else { return .abort(.changed) }
            started = true
        }
        // 移動中は ❯ の行の描き方が変わりうるので、問い・本文・選択肢の数だけで同じメニューかを見る。
        guard current.question == expected.question, current.context == expected.context,
              current.options.count == expected.options.count else { return .abort(.changed) }
        if let from = pressedFrom, current.cursor == from, waited < 4 {
            waited += 1
            return .wait
        }
        pressedFrom = nil
        if current.cursor == target {
            return current.sameMenu(as: expected) ? .confirm : .abort(.changed)
        }
        pressedFrom = current.cursor
        waited = 0
        return .press(current.cursor < target ? .down : .up)
    }
}
