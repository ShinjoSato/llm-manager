import Foundation

/// 吹き出しで扱う Markdown。ブロック（見出し・表・リスト・引用・区切り線・段落・コードブロック）は自前で解析し、
/// 段落内のインライン装飾は `inline(_:)` に任せる。
public enum ChatMarkdown {
    public enum Alignment: Sendable, Equatable {
        case leading, center, trailing
    }

    public struct Table: Sendable, Equatable {
        public var header: [String]
        public var alignments: [Alignment]
        public var rows: [[String]]

        public init(header: [String], alignments: [Alignment], rows: [[String]]) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }
    }

    public struct ListItem: Sendable, Equatable {
        public var blocks: [Block]

        public init(_ blocks: [Block]) { self.blocks = blocks }
    }

    public indirect enum Block: Sendable, Equatable {
        case paragraph(String)
        case heading(level: Int, String)
        case code(language: String?, String)
        case list(ordered: Bool, start: Int, items: [ListItem])
        case quote([Block])
        case table(Table)
        case rule
    }

    /// 入れ子（引用・リスト）の深さの上限。病的な入力で再帰が深くなりすぎないため。
    static let maxDepth = 12

    public static func blocks(_ source: String) -> [Block] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { expandTabs(String($0)) }
        return parse(lines, depth: 0)
    }

    /// 段落内のインライン装飾（太字・斜体・コード・リンク）を解釈する。改行はそのまま残す。読めなければ素の文字列。
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - ブロック

    private static func parse(_ lines: [String], depth: Int) -> [Block] {
        if depth >= maxDepth {
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            return joined.isEmpty ? [] : [.paragraph(joined)]
        }
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                flushParagraph()
                i += 1
                continue
            }
            if let fence = fenceOpening(line) {
                flushParagraph()
                i += 1
                var code: [String] = []
                while i < lines.count, !isFenceClosing(lines[i], fence: fence.marker) {
                    code.append(dropIndent(lines[i], fence.indent))
                    i += 1
                }
                i += 1  // 閉じフェンス（無ければ末尾まで）
                blocks.append(.code(language: fence.language, code.joined(separator: "\n")))
                continue
            }
            if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }
            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }
            if isQuote(line) {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count, isQuote(lines[i]) {
                    inner.append(stripQuote(lines[i]))
                    i += 1
                }
                blocks.append(.quote(parse(inner, depth: depth + 1)))
                continue
            }
            if listMarker(line) != nil {
                flushParagraph()
                blocks.append(parseList(lines, &i, depth: depth))
                continue
            }
            if let table = parseTable(lines, &i) {
                flushParagraph()
                blocks.append(.table(table))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// 段落の途中でも新しいブロックとして扱う行か。
    private static func startsBlock(_ lines: [String], at i: Int) -> Bool {
        let line = lines[i]
        return fenceOpening(line) != nil || heading(line) != nil || isRule(line) || isQuote(line)
            || listMarker(line) != nil || isTableStart(lines, at: i)
    }

    // MARK: - 行の判定

    private static func expandTabs(_ line: String) -> String {
        line.contains("\t") ? line.replacingOccurrences(of: "\t", with: "    ") : line
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func dropIndent(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(min(count, indent(line))))
    }

    private struct Fence {
        var marker: String
        var indent: Int
        var language: String?
    }

    private static func fenceOpening(_ line: String) -> Fence? {
        let ind = indent(line)
        guard ind <= 3 else { return nil }
        let rest = line.dropFirst(ind)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let marker = rest.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        let info = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(marker: String(marker), indent: ind, language: language)
    }

    private static func isFenceClosing(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = fence.first, indent(line) <= 3 else { return false }
        let run = trimmed.prefix { $0 == first }
        return run.count >= fence.count && run.count == trimmed.count
    }

    private static func heading(_ line: String) -> Block? {
        guard indent(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // 末尾の閉じ #（"## 見出し ##"）は飾りなので落とす。
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func isQuote(_ line: String) -> Bool {
        indent(line) <= 3 && line.drop { $0 == " " }.first == ">"
    }

    private static func stripQuote(_ line: String) -> String {
        var rest = line.drop { $0 == " " }.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    struct Marker {
        var indent: Int
        var ordered: Bool
        var number: Int
        var bullet: Character
        var contentIndent: Int
        var text: String
    }

    static func listMarker(_ line: String) -> Marker? {
        let ind = indent(line)
        let rest = line.dropFirst(ind)
        guard let first = rest.first else { return nil }
        var markerLength: Int
        var ordered = false
        var number = 0
        var bullet = first
        if "-*+".contains(first) {
            markerLength = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delim = rest.dropFirst(digits.count).first, delim == "." || delim == ")" else {
                return nil
            }
            markerLength = digits.count + 1
            ordered = true
            number = Int(digits) ?? 1
            bullet = delim
        }
        let after = rest.dropFirst(markerLength)
        if after.isEmpty {
            return Marker(indent: ind, ordered: ordered, number: number, bullet: bullet, contentIndent: ind + markerLength + 1, text: "")
        }
        guard after.first == " " else { return nil }
        let spaces = min(after.prefix { $0 == " " }.count, 4)
        let text = after.drop { $0 == " " }
        return Marker(indent: ind, ordered: ordered, number: number, bullet: bullet,
                      contentIndent: ind + markerLength + spaces, text: String(text))
    }

    // MARK: - リスト

    private static func parseList(_ lines: [String], _ i: inout Int, depth: Int) -> Block {
        guard let first = listMarker(lines[i]) else { return .paragraph(lines[i]) }
        let base = first.indent
        var items: [ListItem] = []

        while i < lines.count, let marker = listMarker(lines[i]), marker.ordered == first.ordered,
              marker.indent <= base + 1, !isRule(lines[i]) {
            var content = [marker.text]
            i += 1
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    // 空行の先が字下げされた続き（入れ子・続きの段落）なら同じ項目に含める。
                    var j = i
                    while j < lines.count, isBlank(lines[j]) { j += 1 }
                    if j < lines.count, indent(lines[j]) > base, listMarker(lines[j]).map({ $0.indent > base + 1 }) ?? true {
                        content.append(contentsOf: Array(repeating: "", count: j - i))
                        i = j
                        continue
                    }
                    if j < lines.count, let next = listMarker(lines[j]), next.indent <= base + 1, next.ordered == first.ordered {
                        i = j
                    }
                    break
                }
                if indent(line) > base + 1 {
                    content.append(dropIndent(line, marker.contentIndent))
                    i += 1
                    continue
                }
                if startsBlock(lines, at: i) { break }
                // 字下げの無い続きの行は同じ項目の段落の続きとみなす。
                content.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            items.append(ListItem(parse(content, depth: depth + 1)))
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    // MARK: - 表

    private static func isTableStart(_ lines: [String], at i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|"), indent(lines[i]) <= 3 else { return false }
        guard let aligns = delimiterRow(lines[i + 1]) else { return false }
        return splitRow(lines[i]).count == aligns.count
    }

    private static func parseTable(_ lines: [String], _ i: inout Int) -> Table? {
        guard isTableStart(lines, at: i), let alignments = delimiterRow(lines[i + 1]) else { return nil }
        let header = splitRow(lines[i])
        var rows: [[String]] = []
        i += 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"),
              fenceOpening(lines[i]) == nil, !isQuote(lines[i]), heading(lines[i]) == nil {
            var cells = splitRow(lines[i])
            if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
            rows.append(Array(cells.prefix(header.count)))
            i += 1
        }
        return Table(header: header, alignments: alignments, rows: rows)
    }

    private static func delimiterRow(_ line: String) -> [Alignment]? {
        guard line.contains("-"), indent(line) <= 3 else { return nil }
        let cells = splitRow(line)
        // 区切り行が "---" だけ（パイプ無し）なら区切り線であって表ではない。
        guard line.contains("|") || cells.count > 1 else { return nil }
        var aligns: [Alignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            let dashes = c.dropFirst(left ? 1 : 0).dropLast(right && c.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            aligns.append(left && right ? .center : right ? .trailing : .leading)
        }
        return aligns.isEmpty ? nil : aligns
    }

    /// 行をセルに割る。`\|` はセル内の文字として扱い、インラインコード内でも区切らない（GFM と同じくエスケープが必要）。
    static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { cell in
            cell.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        }
    }
}
