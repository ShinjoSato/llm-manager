import Foundation

/// ソースの中の `#Preview` 1 つ。
public struct SwiftPreviewDefinition: Equatable, Sendable {
    /// ファイルの上から数えた順番（`PreviewProvider` も数える。RenderPreview の previewDefinitionIndexInFile）。
    public var index: Int
    /// `#Preview("名前")` の名前。無ければ nil。
    public var name: String?
    /// 1 始まりの行。
    public var line: Int

    public init(index: Int, name: String?, line: Int) {
        self.index = index
        self.name = name
        self.line = line
    }
}

/// `#Preview` を持つ Swift ファイル。
public struct SwiftPreviewFile: Equatable, Sendable, Identifiable {
    /// 走査の起点（Xcode のプロジェクトのあるフォルダ）からの相対パス。
    public var relativePath: String
    public var path: String
    public var modified: Date?
    public var previews: [SwiftPreviewDefinition]

    public var id: String { relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }

    public init(relativePath: String, path: String, modified: Date?, previews: [SwiftPreviewDefinition]) {
        self.relativePath = relativePath
        self.path = path
        self.modified = modified
        self.previews = previews
    }
}

/// 走査の結果。
public struct SwiftPreviewScan: Equatable, Sendable {
    public var root: String
    public var files: [SwiftPreviewFile]
    /// ファイル数・フォルダ数の上限で打ち切った。
    public var truncated: Bool

    public var count: Int { files.reduce(0) { $0 + $1.previews.count } }

    public init(root: String, files: [SwiftPreviewFile], truncated: Bool) {
        self.root = root
        self.files = files
        self.truncated = truncated
    }
}

/// Swift のソースから `#Preview` を静的に拾う（ビルドしない）。コメント・文字列の中は数えない。
public enum SwiftPreviews {
    public static let maxDepth = 10
    public static let maxFiles = 5_000
    public static let maxDirectories = 20_000
    /// これより大きいソースは生成物とみなして読まない。
    public static let maxFileSize = 2 * 1024 * 1024
    private static let skippedLowercased = Set(ProjectImages.skipped.map { $0.lowercased() })

    /// Xcode のプロジェクト（`.xcodeproj` / `.xcworkspace`）のあるフォルダ。ソースはふつうこの下にある。
    public static func scanRoot(forXcodeProject path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 起点の下の Swift ファイルを浅い順に読み、`#Preview` のあるものだけを相対パスの自然順で返す。
    public static func scan(root: String, maxDepth: Int = maxDepth, maxFiles: Int = maxFiles,
                            maxDirectories: Int = maxDirectories, isCancelled: () -> Bool = { false },
                            fileManager: FileManager = .default) -> SwiftPreviewScan {
        var files: [SwiftPreviewFile] = []
        var truncated = false
        var swiftCount = 0
        var queue: [(relative: String, depth: Int)] = [(".", 0)]
        var head = 0
        scanning: while head < queue.count {
            if isCancelled() { break }
            if head >= maxDirectories {
                truncated = true
                break
            }
            let (relative, depth) = queue[head]
            head += 1
            let dir = SiteLocator.absolute(relative, in: root)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted(by: ProjectImages.naturalOrder) where !name.hasPrefix(".") {
                let child = (dir as NSString).appendingPathComponent(name)
                let childRelative = relative == "." ? name : "\(relative)/\(name)"
                // リンクは辿らない（循環と、プロジェクトの外のソースを拾わないため）。
                guard let attrs = try? fileManager.attributesOfItem(atPath: child),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    let lower = name.lowercased()
                    let bundle = lower.hasSuffix(".xcodeproj") || lower.hasSuffix(".xcworkspace") || lower.hasSuffix(".xcassets")
                    if depth < maxDepth, !bundle, !skippedLowercased.contains(lower) { queue.append((childRelative, depth + 1)) }
                    continue
                }
                guard type == .typeRegular, name.lowercased().hasSuffix(".swift") else { continue }
                if swiftCount >= maxFiles {
                    truncated = true
                    break scanning
                }
                swiftCount += 1
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                guard size <= maxFileSize, let data = fileManager.contents(atPath: child),
                      containsPreviewWord(data) else { continue }
                let previews = definitions(in: data)
                guard !previews.isEmpty else { continue }
                files.append(SwiftPreviewFile(relativePath: childRelative, path: child,
                                              modified: attrs[.modificationDate] as? Date, previews: previews))
            }
        }
        files.sort { ProjectImages.naturalOrder($0.relativePath, $1.relativePath) }
        return SwiftPreviewScan(root: root, files: files, truncated: truncated)
    }

    /// 字句を読む前の粗いふるい。
    static func containsPreviewWord(_ data: Data) -> Bool {
        data.range(of: Data("#Preview".utf8)) != nil
    }

    public static func definitions(in source: String) -> [SwiftPreviewDefinition] {
        definitions(in: Data(source.utf8))
    }

    /// `#Preview` を上から拾う。`PreviewProvider` に準拠する型は一覧に出さないが、Xcode と番号をそろえるため数える。
    public static func definitions(in data: Data) -> [SwiftPreviewDefinition] {
        var lexer = PreviewLexer(bytes: [UInt8](data))
        lexer.run()
        var result: [SwiftPreviewDefinition] = []
        for (index, found) in lexer.found.enumerated() where !found.provider {
            result.append(SwiftPreviewDefinition(index: index, name: found.name, line: found.line))
        }
        return result
    }
}

/// コメント・文字列（複数行・raw・補間の入れ子）を読み飛ばしながら `#Preview` と、型の宣言の `: PreviewProvider` を探す。
struct PreviewLexer {
    struct Found {
        var name: String?
        var line: Int
        var provider: Bool
    }

    /// 宣言の形を見分けるための、直前の字句（識別子と記号だけ。文字列は 1 つの印）。
    enum Token: Equatable {
        case word(String)
        case symbol(UInt8)
        case literal
    }

    /// 補間の入れ子の上限（壊れた・悪意のあるソースでスタックを使い切らないため）。
    static let maxNesting = 32
    static let historyLimit = 64

    let bytes: [UInt8]
    var i = 0
    var line = 1
    var found: [Found] = []
    private var history: [Token] = []
    private var nesting = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() {
        scanCode(untilCloseParen: false)
    }

    private func at(_ k: Int) -> UInt8? { k < bytes.count ? bytes[k] : nil }

    static func isIdentifier(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    private func matches(_ word: String, at k: Int) -> Bool {
        let w = Array(word.utf8)
        guard k + w.count <= bytes.count else { return false }
        for j in 0..<w.count where bytes[k + j] != w[j] { return false }
        return true
    }

    /// コードを読む。`untilCloseParen` なら対応の取れない `)` で止まる（文字列の補間の中）。
    private mutating func scanCode(untilCloseParen: Bool) {
        var depth = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0A:
                line += 1
                i += 1
            case 0x20, 0x09, 0x0D:
                i += 1
            case 0x2F where at(i + 1) == 0x2F:
                skipLineComment()
            case 0x2F where at(i + 1) == 0x2A:
                skipBlockComment()
            case 0x22:
                skipString(hashes: 0)
                remember(.literal)
            case 0x23:
                if let hashes = rawStringHashes(at: i) {
                    i += hashes
                    skipString(hashes: hashes)
                    remember(.literal)
                } else if matches("#Preview", at: i), !(at(i + 8).map(Self.isIdentifier) ?? false),
                          !(i > 0 && Self.isIdentifier(bytes[i - 1])) {
                    let startLine = line
                    i += 8
                    if !untilCloseParen { found.append(Found(name: previewName(), line: startLine, provider: false)) }
                    remember(.literal)
                } else {
                    i += 1
                    remember(.symbol(b))
                }
            case 0x28:
                depth += 1
                i += 1
                remember(.symbol(b))
            case 0x29:
                if untilCloseParen && depth == 0 {
                    i += 1
                    return
                }
                depth -= 1
                i += 1
                remember(.symbol(b))
            default:
                // 識別子は 1 語ずつ進める（語の途中の `PreviewProvider` を拾わないため）。
                guard Self.isIdentifier(b) else {
                    i += 1
                    remember(.symbol(b))
                    continue
                }
                let start = i
                while i < bytes.count, Self.isIdentifier(bytes[i]) { i += 1 }
                let word = String(decoding: bytes[start..<i], as: UTF8.self)
                if word == "PreviewProvider", !untilCloseParen, Self.isConformanceInTypeDeclaration(history) {
                    found.append(Found(name: nil, line: line, provider: true))
                }
                remember(.word(word))
            }
        }
    }

    private mutating func remember(_ token: Token) {
        history.append(token)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    private static let declarationKeywords: Set<String> = ["struct", "class", "enum", "actor", "extension"]

    /// `PreviewProvider` の直前の字句が、型の宣言の継承節（`struct X: A, SwiftUI.PreviewProvider`）か。
    /// ジェネリクスの制約（`<T: PreviewProvider>`・`where T: PreviewProvider`）・型注釈（`let x: PreviewProvider`）は数えない。
    static func isConformanceInTypeDeclaration(_ tokens: [Token]) -> Bool {
        var k = tokens.count - 1
        // `SwiftUI.PreviewProvider` の修飾。
        if k >= 1, tokens[k] == .symbol(0x2E), tokens[k - 1] == .word("SwiftUI") { k -= 2 }
        // 継承節の先頭の `:` まで、型の並び（`A`・`A.B`・`A<T>`・`,`）を遡る。
        while k >= 0 {
            switch tokens[k] {
            case .symbol(0x3A):
                return declaresType(tokens, before: k - 1)
            case .symbol(0x2C):
                k -= 1
                guard let next = skipType(tokens, from: k) else { return false }
                k = next
            default:
                return false
            }
        }
        return false
    }

    /// `k` から遡って型 1 つ（`A.B<C, D>`・`any`/`&` は無し）を読み飛ばし、その前の位置を返す。
    private static func skipType(_ tokens: [Token], from start: Int) -> Int? {
        var k = start
        if k >= 0, tokens[k] == .symbol(0x3E) {
            var depth = 0
            while k >= 0 {
                if tokens[k] == .symbol(0x3E) { depth += 1 }
                if tokens[k] == .symbol(0x3C) { depth -= 1 }
                k -= 1
                if depth == 0 { break }
            }
            guard depth == 0 else { return nil }
        }
        guard k >= 0, case .word = tokens[k] else { return nil }
        k -= 1
        while k >= 1, tokens[k] == .symbol(0x2E), case .word = tokens[k - 1] { k -= 2 }
        return k
    }

    /// `:` の前が `struct 名前` / `class 名前<T>` / `extension A.B` か。
    private static func declaresType(_ tokens: [Token], before start: Int) -> Bool {
        guard let k = skipType(tokens, from: start), k >= 0, case .word(let keyword) = tokens[k] else { return false }
        return declarationKeywords.contains(keyword)
    }

    /// `#` の並びの後に `"` が来れば raw 文字列。その `#` の数。
    private func rawStringHashes(at k: Int) -> Int? {
        var j = k
        while j < bytes.count, bytes[j] == 0x23 { j += 1 }
        return at(j) == 0x22 ? j - k : nil
    }

    private mutating func skipLineComment() {
        while i < bytes.count, bytes[i] != 0x0A { i += 1 }
    }

    private mutating func skipBlockComment() {
        var depth = 0
        while i < bytes.count {
            if bytes[i] == 0x2F, at(i + 1) == 0x2A {
                depth += 1
                i += 2
            } else if bytes[i] == 0x2A, at(i + 1) == 0x2F {
                depth -= 1
                i += 2
                if depth == 0 { return }
            } else {
                if bytes[i] == 0x0A { line += 1 }
                i += 1
            }
        }
    }

    /// `i` は開きの `"`。閉じの後ろまで進め、補間を含まない時だけ中身を返す。
    @discardableResult
    private mutating func skipString(hashes: Int) -> String? {
        let multiline = at(i + 1) == 0x22 && at(i + 2) == 0x22
        let quotes = multiline ? 3 : 1
        i += quotes
        var content: [UInt8] = []
        var simple = true
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x22, closes(at: i, quotes: quotes, hashes: hashes) {
                i += quotes + hashes
                return simple ? String(decoding: content, as: UTF8.self) : nil
            }
            if b == 0x5C, escapeHashesMatch(at: i + 1, hashes: hashes) {
                let next = i + 1 + hashes
                if at(next) == 0x28 {
                    // 補間の中はコードとして読む（中の文字列・括弧の入れ子を越える）。
                    i = next + 1
                    simple = false
                    guard nesting < Self.maxNesting else {
                        // 入れ子が深すぎるソースはここで読むのをやめる（それより後は数えない）。
                        i = bytes.count
                        return nil
                    }
                    nesting += 1
                    let saved = history
                    scanCode(untilCloseParen: true)
                    history = saved
                    nesting -= 1
                    continue
                }
                if let n = at(next) {
                    if n == 0x0A { line += 1 }
                    content.append(Self.unescaped(n))
                }
                i = next + 1
                continue
            }
            if b == 0x0A {
                line += 1
                // 1 行の文字列が閉じずに改行したら、壊れたソースとしてそこで切り上げる。
                if !multiline {
                    i += 1
                    return nil
                }
            }
            content.append(b)
            i += 1
        }
        return nil
    }

    private func closes(at k: Int, quotes: Int, hashes: Int) -> Bool {
        for j in 0..<quotes where at(k + j) != 0x22 { return false }
        for j in 0..<hashes where at(k + quotes + j) != 0x23 { return false }
        return true
    }

    private func escapeHashesMatch(at k: Int, hashes: Int) -> Bool {
        for j in 0..<hashes where at(k + j) != 0x23 { return false }
        return true
    }

    private static func unescaped(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x6E: return 0x0A
        case 0x74: return 0x09
        case 0x72: return 0x0D
        case 0x30: return 0x00
        default: return b
        }
    }

    /// `#Preview` の直後。最初の引数がラベルの無い文字列なら名前。
    private mutating func previewName() -> String? {
        skipTrivia()
        guard at(i) == 0x28 else { return nil }
        i += 1
        skipTrivia()
        let hashes = rawStringHashes(at: i) ?? 0
        guard at(i + hashes) == 0x22 else { return nil }
        i += hashes
        let name = skipString(hashes: hashes)
        skipTrivia()
        guard at(i) == 0x2C || at(i) == 0x29 else { return nil }
        return name
    }

    private mutating func skipTrivia() {
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0D {
                i += 1
            } else if b == 0x0A {
                line += 1
                i += 1
            } else if b == 0x2F, at(i + 1) == 0x2F {
                skipLineComment()
            } else if b == 0x2F, at(i + 1) == 0x2A {
                skipBlockComment()
            } else {
                return
            }
        }
    }
}
