import Foundation

/// 右に縦線か空白の桁で区切って並ぶ別の欄（差分パネル等）を除く。判定は左の会話・メニュー・入力欄だけを見る前提のため。
extension TerminalScreen {
    /// 区切りとみなす縦線が続く最小の行数（会話の表や枠付きの問いの短い縦線と取り違えないため）。
    static let paneDividerMinRows = 8
    /// 区切りの左に残る最小の桁数（左端の枠線・字下げした引用の縦線を区切りと読まないため）。
    static let paneDividerMinColumn = 20
    /// 空白の区切りで、右の欄の文字が始まる位置の幅（区切りの次の桁かその次）。
    static let blankDividerReach = 2
    /// 空白の区切りで、左右の両方に文字のある行の最小数（左に寄せただけの短い行の並びを 2 つの欄と読まないため）。
    static let blankDividerMinSharedRows = 4

    /// 右の欄を除いた画面（行の数と順は変えない）。区切りが無ければそのまま返す。
    public static func mainPane(_ screen: [String]) -> [String] {
        guard let (column, rows) = paneDivider(screen) ?? blankDivider(screen) else { return screen }
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

    /// 全行で空白の桁の区切りと切る行。桁をそろえた文や表と取り違えないよう、すぐ右から始まる行・左右に文字のある行・手前で切れた左の罫線が揃う時だけ。
    static func blankDivider(_ screen: [String]) -> (column: Int, rows: [Int])? {
        let cells = screen.map(cellSpans)
        let width = cells.compactMap { $0.last.map { $0.column + $0.width } }.max() ?? 0
        guard width > paneDividerMinColumn + blankDividerReach else { return nil }
        var occupied = [Bool](repeating: false, count: width)
        for row in cells {
            for cell in row where !cell.character.isWhitespace {
                for column in cell.column..<(cell.column + cell.width) { occupied[column] = true }
            }
        }
        // 空白の桁ごとに、すぐ右（`blankDividerReach` 桁以内）から文字が始まる行と、そのうち左にも文字のある行を数える。
        var rightRows: [Int: Int] = [:]
        var shared: [Int: Int] = [:]
        for line in cells {
            var counted = Set<Int>()
            var leftmost: Int?
            for cell in line where !cell.character.isWhitespace {
                defer { if leftmost == nil { leftmost = cell.column } }
                guard !"│┃║".contains(cell.character) else { continue }
                for distance in 1...blankDividerReach {
                    let column = cell.column - distance
                    guard column >= paneDividerMinColumn, !occupied[column], counted.insert(column).inserted else { continue }
                    rightRows[column, default: 0] += 1
                    if let leftmost, leftmost < column { shared[column, default: 0] += 1 }
                }
            }
        }
        for column in rightRows.keys.sorted() {
            guard rightRows[column, default: 0] >= paneDividerMinRows, shared[column, default: 0] >= blankDividerMinSharedRows,
                  cells.contains(where: { endsAsLeftRule($0, before: column) }) else { continue }
            // 区切りから右に文字のある行は全部切る（右の欄の中で字下げした行も含める）。
            let rows = cells.indices.filter { row in cells[row].contains { $0.column > column && !$0.character.isWhitespace } }
            return (column, rows)
        }
        return nil
    }

    /// 区切りの手前（`blankDividerReach` 桁以内）で終わる、左の欄だけの罫線の行か（左右に分かれた画面では入力欄などの罫線が左の欄の幅で切れる）。
    private static func endsAsLeftRule(_ line: [(character: Character, column: Int, width: Int)], before column: Int) -> Bool {
        let left = line.filter { $0.column < column && !$0.character.isWhitespace }
        guard let last = left.last, column - (last.column + last.width) < blankDividerReach else { return false }
        return PermissionPrompt.isSeparator(String(left.map(\.character)))
    }

    /// 行の各文字と、表示上の桁・幅。
    private static func cellSpans(_ line: String) -> [(character: Character, column: Int, width: Int)] {
        var result: [(character: Character, column: Int, width: Int)] = []
        var column = 0
        for character in line {
            let width = displayWidth(of: character)
            result.append((character, column, width))
            column += width
        }
        return result
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
