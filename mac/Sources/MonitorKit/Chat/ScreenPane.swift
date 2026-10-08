import Foundation

/// 右に縦線（│）で区切って並ぶ別の欄（差分パネル等）を除く。判定は左の会話・メニュー・入力欄だけを見る前提のため。
extension TerminalScreen {
    /// 区切りとみなす縦線が続く最小の行数（会話の表や枠付きの問いの短い縦線と取り違えないため）。
    static let paneDividerMinRows = 8
    /// 区切りの左に残る最小の桁数（左端の枠線・字下げした引用の縦線を区切りと読まないため）。
    static let paneDividerMinColumn = 20

    /// 右の欄を除いた画面（行の数と順は変えない）。区切りが無ければそのまま返す。
    public static func mainPane(_ screen: [String]) -> [String] {
        guard let (column, rows) = paneDivider(screen) else { return screen }
        var result = screen
        for row in rows {
            guard let index = characterIndex(in: screen[row], atColumn: column) else { continue }
            let characters = Array(screen[row])
            result[row] = String(characters[..<index]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        return result
    }

    /// 区切りの桁と、そこで切る行。全幅の罫線（入力欄の上下等）で区切りが途切れるので、続いている範囲だけを切る。
    static func paneDivider(_ screen: [String]) -> (column: Int, rows: [Int])? {
        let columns = screen.map(barColumns)
        let candidates = Set(columns.flatMap { $0 }).filter { $0 >= paneDividerMinColumn }.sorted()
        for column in candidates {
            guard let rows = longestRun(columns: columns, screen: screen, column: column), rows.count >= paneDividerMinRows else { continue }
            // 表の行は左端も縦線で始まる。右の欄の区切りなら左は本文か空白。
            let tableLike = rows.filter { row in
                guard let first = screen[row].firstIndex(where: { !$0.isWhitespace }), screen[row][first] == "│" else { return false }
                return displayWidth(of: screen[row][..<first]) < column
            }
            guard tableLike.count * 2 < rows.count else { continue }
            guard rows.contains(where: { row in
                screen[row].first { !$0.isWhitespace }.map { $0 != "│" } ?? false
            }) else { continue }
            return (column, rows)
        }
        return nil
    }

    /// `column` に縦線のある行が続く最長の範囲。1 行だけの途切れ（幅の数え違い）はつなぐが、罫線の行ではつながない。
    private static func longestRun(columns: [Set<Int>], screen: [String], column: Int) -> [Int]? {
        var best: [Int] = []
        var current: [Int] = []
        var gap = 0
        for row in columns.indices {
            if columns[row].contains(column) {
                current.append(row)
                gap = 0
                continue
            }
            gap += 1
            if gap > 1 || PermissionPrompt.isSeparator(screen[row]) {
                if current.count > best.count { best = current }
                current = []
            }
        }
        if current.count > best.count { best = current }
        return best.isEmpty ? nil : best
    }

    /// 行の中の縦線（│）の表示上の桁。
    static func barColumns(_ line: String) -> Set<Int> {
        var result = Set<Int>()
        var column = 0
        for character in line {
            if character == "│" { result.insert(column) }
            column += displayWidth(of: character)
        }
        return result
    }

    /// 表示上の桁 `column` から始まる文字の位置（Character の添字）。その桁で始まる文字が無ければ nil。
    static func characterIndex(in line: String, atColumn column: Int) -> Int? {
        var current = 0
        for (index, character) in line.enumerated() {
            if current == column { return index }
            if current > column { return nil }
            current += displayWidth(of: character)
        }
        return nil
    }

    static func displayWidth<S: StringProtocol>(of text: S) -> Int {
        text.reduce(0) { $0 + displayWidth(of: $1) }
    }

    /// 端末での文字の幅（全角・絵文字は 2）。East Asian Width が W/F の主な範囲と絵文字表示の文字だけを 2 とする近似。
    static func displayWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) || scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
