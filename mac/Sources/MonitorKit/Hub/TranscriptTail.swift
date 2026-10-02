import Foundation

// 実況層（移植元: monitor/src/transcript.ts）。jsonl の末尾差分から「今なにをしているか」を取り出す。
// ログの単位はターン／ツール呼び出しで、トークン単位ではない。

/// ツール呼び出しの中身。キャラの持ち物と一言に使う。
public struct ToolDetail: Sendable, Equatable {
    public var name: String
    public var skill: String?
    public var subagentType: String?
    public var description: String?
}

/// user 行の中身。tool_result と実際のユーザー入力を区別する。
public enum UserLineKind: Sendable, Equatable {
    case toolResult
    case prompt
}

public struct ParsedEvent: Sendable, Equatable {
    public var type: String
    public var at: Double?
    public var title: String?
    public var lastPrompt: String?
    public var branch: String?
    public var tools: [String]?
    public var toolDetail: ToolDetail?
    public var userKind: UserLineKind?
    public var text: String?
    public var usage: TokenUsage?
}

public enum TranscriptTail {
    /// 初回に遡って読む量。ログは数 MB まで育つので全読みしない。
    public static let bootstrapBytes = 512 * 1024
    /// メタ情報スキャンの上限。巨大なログでも初回が止まらないようにする。
    public static let maxScanBytes = 32 * 1024 * 1024

    /// ユーザーが打った指示はタグで始まらない。スラッシュコマンドだけは指示として扱う。
    static let userTags: Set<String> = ["command-name", "command-message"]

    /// user 行が仕組み側の注入か。種別は増えるので列挙せず「タグで始まるか」で見る。
    public static func isInjected(_ content: Any?) -> Bool {
        let text: String
        if let s = content as? String {
            text = s
        } else if let list = content as? [Any] {
            text = list.compactMap { item -> String? in
                guard let c = item as? [String: Any], JSONLoose.string(c["type"]) == "text" else { return nil }
                return JSONLoose.string(c["text"]) ?? ""
            }.joined()
        } else {
            text = ""
        }
        guard let tag = leadingTag(text) else { return false }
        return !userTags.contains(tag)
    }

    /// `^\s*<([a-zA-Z][\w-]*)` のタグ名。
    static func leadingTag(_ text: String) -> String? {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace { scalars = scalars.dropFirst() }
        guard scalars.first == "<" else { return nil }
        scalars = scalars.dropFirst()
        guard let head = scalars.first, head.isASCIILetter else { return nil }
        var name = String.UnicodeScalarView()
        for s in scalars {
            guard s.isASCIILetter || s.isASCIIDigit || s == "_" || s == "-" else { break }
            name.append(s)
        }
        return String(name)
    }

    static func toolDetail(name: String, input: Any?) -> ToolDetail {
        var detail = ToolDetail(name: name)
        guard let o = input as? [String: Any] else { return detail }
        detail.skill = JSONLoose.string(o["skill"])
        detail.subagentType = JSONLoose.string(o["subagent_type"])
        detail.description = JSONLoose.string(o["description"])
        return detail
    }

    public static func parseLine(_ bytes: some Collection<UInt8>) -> ParsedEvent? {
        guard let o = JSONLoose.dict(JSONLoose.object(bytes)) else { return nil }
        return parse(o)
    }

    public static func parse(_ o: [String: Any]) -> ParsedEvent {
        let type = JSONLoose.string(o["type"]) ?? "unknown"
        var ev = ParsedEvent(type: type, at: JSONLoose.timestamp(o["timestamp"]))
        if let branch = JSONLoose.string(o["gitBranch"]), !branch.isEmpty { ev.branch = branch }
        if type == "ai-title", let title = JSONLoose.string(o["aiTitle"]) { ev.title = title }
        if type == "last-prompt", let prompt = JSONLoose.string(o["lastPrompt"]) { ev.lastPrompt = prompt }

        if type == "user", let message = o["message"] as? [String: Any] {
            let content = message["content"]
            let isResult = (content as? [Any])?.contains { ($0 as? [String: Any]).flatMap { JSONLoose.string($0["type"]) } == "tool_result" } ?? false
            ev.userKind = isResult || JSONLoose.isTrue(o["isMeta"]) || isInjected(content) ? .toolResult : .prompt
        }

        if type == "assistant", let message = o["message"] as? [String: Any] {
            let content = (message["content"] as? [Any]) ?? []
            var tools: [String] = []
            var text = ""
            for item in content {
                guard let c = item as? [String: Any] else { continue }
                let kind = JSONLoose.string(c["type"])
                if kind == "tool_use", let name = JSONLoose.string(c["name"]) {
                    tools.append(name)
                    let detail = toolDetail(name: name, input: c["input"])
                    // skill 付きは最優先。それ以外は currentTool と揃うよう後勝ちにする。
                    if detail.skill != nil || ev.toolDetail?.skill == nil { ev.toolDetail = detail }
                } else if kind == "text", let t = JSONLoose.string(c["text"]) {
                    text += t
                }
            }
            if !tools.isEmpty { ev.tools = tools }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ev.text = trimmed }

            if let u = message["usage"] as? [String: Any] {
                ev.usage = TokenUsage(input: Int(JSONLoose.coerceNumber(u["input_tokens"])),
                                      output: Int(JSONLoose.coerceNumber(u["output_tokens"])),
                                      cacheRead: Int(JSONLoose.coerceNumber(u["cache_read_input_tokens"])))
            }
        }
        return ev
    }

    /// 初回だけログを広く遡ってメタ情報を拾う。ai-title / last-prompt はセッション中に数回しか現れず、末尾読みだけでは取りこぼす。
    public static func primeMeta(path: String) -> (title: String?, lastPrompt: String?) {
        guard let size = Bytes.size(path) else { return (nil, nil) }
        let start = max(0, size - maxScanBytes)
        guard size > start, let bytes = Bytes.read(path, offset: start, length: size - start) else { return (nil, nil) }
        var title: String?
        var lastPrompt: String?
        let aiTitle = Array(#""ai-title""#.utf8)
        let lastPromptKey = Array(#""last-prompt""#.utf8)
        var lineStart = 0
        bytes.withUnsafeBytes { buf in
            while lineStart < buf.count {
                let rest = UnsafeRawBufferPointer(rebasing: buf[lineStart...])
                let nl = rest.firstIndex(of: 0x0A).map { lineStart + $0 } ?? buf.count
                let line = UnsafeRawBufferPointer(rebasing: buf[lineStart..<nl])
                // 全行を JSON 化すると重いので、対象の type を含む行だけに絞る。
                if Bytes.contains(line, aiTitle) || Bytes.contains(line, lastPromptKey), let ev = parseLine(line) {
                    if let t = ev.title { title = t }
                    if let p = ev.lastPrompt { lastPrompt = p }
                }
                lineStart = nl + 1
            }
        }
        return (title, lastPrompt)
    }
}

/// 1 セッション分のログを差分で読む。初回は末尾だけを読んで現在の状態を復元し、以降は追記分のみを返す。
public final class TranscriptReader {
    public let path: String
    private var offset = 0
    /// 書き込み途中の行。バイトのまま持ち越すので、境界を跨いだマルチバイト文字も壊れない。
    private var carry: [UInt8] = []
    private var primed = false

    public init(path: String) {
        self.path = path
    }

    private func reset() {
        offset = 0
        carry = []
        primed = false
    }

    /// サイズが変わっていなければ何もしない。追記分をパースして返す。
    public func read() -> [ParsedEvent] {
        guard let size = Bytes.size(path) else { return [] }
        if size < offset { reset() } // ローテートや切り詰め
        if size == offset && primed { return [] }

        var start = offset
        var dropFirstLine = false
        if !primed {
            start = max(0, size - TranscriptTail.bootstrapBytes)
            if start > 0 {
                // 直前の 1 バイトも読む。それが改行なら分割後の先頭が空になり、行を失わない。
                start -= 1
                dropFirstLine = true
            }
        }
        if size <= start {
            offset = size
            primed = true
            return []
        }
        guard let chunk = Bytes.read(path, offset: start, length: size - start) else { return [] }
        offset = start + chunk.count
        primed = true

        var buffer = carry
        buffer.append(contentsOf: chunk)
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = 0
        for i in buffer.indices where buffer[i] == 0x0A {
            lines.append(buffer[lineStart..<i])
            lineStart = i + 1
        }
        carry = Array(buffer[lineStart...]) // 最後は書き込み途中の可能性があるので持ち越す
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }

        var events: [ParsedEvent] = []
        for line in lines {
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { continue }
            if let ev = TranscriptTail.parseLine(line) { events.append(ev) }
        }
        return events
    }
}

extension Unicode.Scalar {
    var isASCIILetter: Bool { (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) }
    var isASCIIDigit: Bool { (0x30...0x39).contains(value) }
}
