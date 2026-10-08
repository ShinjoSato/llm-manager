import Foundation

// 会話履歴。1 セッションの jsonl を最初から読み、チャット表示の単位（発話・応答・ツール）に整形する。

public enum TranscriptFormat {
    /// 1 回に読む量。数十 MB のログでも巨大なバッファを一度に確保しない。
    static let chunkBytes = 4 * 1024 * 1024
    /// ツールの要約 1 項目の上限。コマンドやパターンは長くなりうる。
    static let maxSummaryChars = 300
    /// 画像の取り出しで 1 行として読む上限。壊れた位置情報で巨大な読み込みをしない。
    static let maxImageLineBytes = 64 * 1024 * 1024
    /// 返してよい画像の形式。SVG 等の文書型はスクリプトが動きうるので通さない。
    public static let imageMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// パスに埋め込みうるので、UUID 相当の文字だけを通す（`..` や `/` を入れさせない）。
    public static func isValidSessionId(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" }
    }

    /// 履歴の要素 id（`<uuid>:<ブロック番号>` / `line<N>:<ブロック番号>`）。
    public static func isValidItemId(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, isValidSessionId(String(parts[0])) else { return false }
        return (1...6).contains(parts[1].count) && parts[1].unicodeScalars.allSatisfy(\.isASCIIDigit)
    }

    /// content の画像ブロックを順に返す（`index` は形式を問わず数えた位置）。
    static func imageBlocks(_ content: Any?) -> [(index: Int, block: [String: Any])] {
        guard let list = content as? [Any] else { return [] }
        var out: [(Int, [String: Any])] = []
        for item in list {
            if let c = item as? [String: Any], JSONLoose.string(c["type"]) == "image" { out.append((out.count, c)) }
        }
        return out
    }

    static func servableSource(_ block: [String: Any]) -> (mediaType: String, data: String)? {
        guard let source = block["source"] as? [String: Any], JSONLoose.string(source["type"]) == "base64",
              let data = JSONLoose.string(source["data"]), let mediaType = JSONLoose.string(source["media_type"]),
              imageMediaTypes.contains(mediaType) else { return nil }
        return (mediaType, data)
    }

    /// 発話に添えられた画像の目録。取り出せる形式（base64 の PNG / JPEG / GIF / WebP）だけを載せる。
    public static func images(of content: Any?) -> [TranscriptImage] {
        imageBlocks(content).compactMap { entry in
            servableSource(entry.block).map { TranscriptImage(index: entry.index, mediaType: $0.mediaType) }
        }
    }

    /// `index` 枚目の画像の本体。取り出せない形式・範囲外なら nil。
    public static func imageData(of content: Any?, index: Int) -> TranscriptImageData? {
        guard let found = imageBlocks(content).first(where: { $0.index == index }),
              let source = servableSource(found.block),
              let data = Data(base64Encoded: source.data, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return TranscriptImageData(mediaType: source.mediaType, data: data)
    }

    static func clip(_ text: String, _ max: Int = maxSummaryChars) -> String {
        HubText.clip(text, max)
    }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 対象として一番わかりやすいものを 1 つだけ選ぶ。
    public static func summarizeTool(name: String, input: Any?) -> TranscriptTool {
        let o = (input as? [String: Any]) ?? [:]
        let command = str(o["command"])
        let pattern = str(o["pattern"])
        let path = str(o["path"])
        let patternTarget: String? = {
            guard let pattern else { return nil }
            if let path { return "\(pattern) (\(path))" }
            return pattern
        }()
        let firstLine: String? = command.map { String($0.split(separator: "\n", omittingEmptySubsequences: false).first ?? "") }
        let candidates: [String?] = [str(o["file_path"]), str(o["notebook_path"]), firstLine, patternTarget,
                                     str(o["url"]), str(o["query"]), str(o["skill"]), str(o["subagent_type"]), path]
        let target = candidates.lazy.compactMap { $0 }.first
        let description = str(o["description"])
        return TranscriptTool(name: name, description: description.map { clip($0) }, target: target.map { clip($0) })
    }

    /// ユーザー行の本文。スラッシュコマンドは打った形（`/name args`）に戻す。
    static func promptText(_ content: Any?) -> String? {
        var text: String
        if let s = content as? String {
            text = s
        } else if let list = content as? [Any] {
            text = list.compactMap { item -> String? in
                guard let c = item as? [String: Any] else { return nil }
                let type = JSONLoose.string(c["type"])
                if type == "text", let t = JSONLoose.string(c["text"]) { return t.isEmpty ? nil : t }
                if type == "image" { return "[画像]" }
                return nil
            }.joined(separator: "\n")
        } else {
            return nil
        }
        if let command = between(text, "<command-name>", "</command-name>")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            let args = between(text, "<command-args>", "</command-args>")?.trimmingCharacters(in: .whitespacesAndNewlines)
            text = args.map { $0.isEmpty ? command : "\(command) \($0)" } ?? command
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// jsonl の 1 行（パース済み）をチャットの要素に変換する。対象外の行は空。`parentId` は行をまたいで引き継ぐ。
    public static func items(fromLine o: [String: Any], lineKey: String, parentId: inout String?) -> [TranscriptItem] {
        guard let message = o["message"] as? [String: Any] else { return [] }
        // サブエージェントや要約は親の会話としては見せない。
        if JSONLoose.isTrue(o["isSidechain"]) || JSONLoose.isTrue(o["isMeta"]) || JSONLoose.isTrue(o["isCompactSummary"]) { return [] }
        let base = JSONLoose.string(o["uuid"]).flatMap { $0.isEmpty ? nil : $0 } ?? lineKey
        let at = JSONLoose.timestamp(o["timestamp"])
        let content = message["content"]
        let type = JSONLoose.string(o["type"])

        if type == "user" {
            if TranscriptTail.isToolResult(content) || TranscriptTail.isInjected(content) { return [] }
            guard let text = promptText(content) else { return [] }
            let id = "\(base):0"
            parentId = id
            return [TranscriptItem(id: id, kind: .user, at: at, text: text, tool: nil, parentId: nil, images: images(of: content))]
        }

        guard type == "assistant", let list = content as? [Any] else { return [] }
        var out: [TranscriptItem] = []
        for (i, item) in list.enumerated() {
            guard let c = item as? [String: Any] else { continue }
            let id = "\(base):\(i)"
            let kind = JSONLoose.string(c["type"])
            if kind == "text", let t = JSONLoose.string(c["text"]) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                out.append(TranscriptItem(id: id, kind: .assistant, at: at, text: trimmed, tool: nil, parentId: nil, images: []))
                parentId = id
            } else if kind == "tool_use", let name = JSONLoose.string(c["name"]) {
                out.append(TranscriptItem(id: id, kind: .tool, at: at, text: nil,
                                          tool: summarizeTool(name: name, input: c["input"]), parentId: parentId, images: []))
            }
        }
        return out
    }

    /// 読み直した行が画像付きの発話か。uuid が分かっていれば一致も見る。
    static func isImageLine(_ o: Any?, uuid: String?) -> Bool {
        guard let o = o as? [String: Any], JSONLoose.string(o["type"]) == "user" else { return false }
        if let uuid, JSONLoose.string(o["uuid"]) != uuid { return false }
        return !images(of: (o["message"] as? [String: Any])?["content"]).isEmpty
    }
}

/// 発話に添えられた画像 1 枚の本体。
public struct TranscriptImageData: Sendable, Equatable {
    public var mediaType: String
    public var data: Data
}

/// 1 セッション分のログを先頭から読み、以降は追記分だけを読む。画像の本体は手元に持たず、求められた時に行を読み直す。
final class TranscriptLog {
    let path: String
    private(set) var items: [TranscriptItem] = []
    private var index: [String: Int] = [:]
    private var offset = 0
    /// 書きかけの行の断片。位置をバイトで数えるため、文字列にせずに持ち越す。
    private var carry: [UInt8] = []
    private var lineNo = 0
    /// 持ち越し中の行がファイルの何バイト目から始まるか。
    private var lineStart = 0
    private var parentId: String?

    struct ImageLineRef: Equatable, Sendable {
        var offset: Int
        var length: Int
        var uuid: String?
    }

    struct DecodedImages: Sendable {
        var images: [TranscriptImageData?]
        var bytes: Int
    }

    /// 画像付きの発話 id → その行の位置。
    var imageLines: [String: ImageLineRef] = [:]
    /// 直近に解析した画像付きの行（LRU。先頭が古い）。同じ発話の複数枚を 1 回の読み込みで返す。
    private(set) var decodedOrder: [String] = []
    private var decoded: [String: DecodedImages] = [:]
    private(set) var decodedBytes = 0
    /// 画像のために行を読み直した回数（試験用）。
    private(set) var lineReads = 0

    /// 解析済みの画像を持っておく行数と合計の上限。
    static let maxDecodedLines = 4
    static let maxDecodedBytes = 32 * 1024 * 1024

    init(path: String) {
        self.path = path
    }

    private func reset() {
        items = []
        index = [:]
        imageLines = [:]
        clearDecoded()
        offset = 0
        lineStart = 0
        carry = []
        lineNo = 0
        parentId = nil
    }

    func clearDecoded() {
        decoded = [:]
        decodedOrder = []
        decodedBytes = 0
    }

    /// 追記分を読み、新しく増えた要素だけを返す。
    func read() -> [TranscriptItem] {
        guard let size = Bytes.size(path) else { return [] }
        if size < offset { reset() } // 切り詰められたら読み直す
        if size == offset { return [] }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var fresh: [TranscriptItem] = []
        var buf = [UInt8](repeating: 0, count: min(TranscriptFormat.chunkBytes, size - offset))
        while offset < size {
            let want = min(buf.count, size - offset)
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            offset += n
            var start = 0
            for i in 0..<n where buf[i] == 0x0A {
                let line: [UInt8] = carry.isEmpty ? Array(buf[start..<i]) : carry + buf[start..<i]
                carry = []
                parseLine(line, into: &fresh, offset: lineStart)
                lineStart += line.count + 1
                start = i + 1
            }
            // 書き込み途中の行は次回に回す。
            if start < n { carry.append(contentsOf: buf[start..<n]) }
        }
        return fresh
    }

    private static let userKey = Array(#""user""#.utf8)
    private static let assistantKey = Array(#""assistant""#.utf8)

    private func parseLine(_ line: [UInt8], into fresh: inout [TranscriptItem], offset: Int) {
        lineNo += 1
        let key = "line\(lineNo)"
        // 対象の行だけ JSON 化する（ログの大半は添付や履歴スナップショット）。
        guard Bytes.contains(line, Self.userKey) || Bytes.contains(line, Self.assistantKey),
              let o = JSONLoose.dict(JSONLoose.object(line)) else { return }
        for item in TranscriptFormat.items(fromLine: o, lineKey: key, parentId: &parentId) {
            guard index[item.id] == nil else { continue }
            index[item.id] = items.count
            items.append(item)
            fresh.append(item)
            if !item.images.isEmpty {
                imageLines[item.id] = ImageLineRef(offset: offset, length: line.count, uuid: JSONLoose.string(o["uuid"]))
            }
        }
    }

    /// 画像の引き当て。読み直しが要る時は、その材料（ファイルの位置）を返す。
    enum ImageLookup {
        case cached(TranscriptImageData?)
        case load(path: String, ref: ImageLineRef)
        case missing
    }

    func lookupImage(itemId: String, index: Int) -> ImageLookup {
        if let hit = decoded[itemId] {
            decodedOrder.removeAll { $0 == itemId }
            decodedOrder.append(itemId)
            return .cached(hit.images.indices.contains(index) ? hit.images[index] : nil)
        }
        guard let ref = imageLines[itemId] else { return .missing }
        lineReads += 1
        return .load(path: path, ref: ref)
    }

    /// 発話 `itemId` の `index` 枚目の画像。行を読み直して取り出す。見つからなければ nil。
    func image(itemId: String, index: Int) -> TranscriptImageData? {
        switch lookupImage(itemId: itemId, index: index) {
        case .cached(let hit): return hit
        case .missing: return nil
        case .load(let path, let ref):
            guard let (loaded, found) = Self.loadImages(path: path, ref: ref) else { return nil }
            return storeLoaded(itemId: itemId, loaded, ref: found, index: index)
        }
    }

    /// 読み直した結果を覚えて、`index` 枚目を返す。
    func storeLoaded(itemId: String, _ loaded: DecodedImages, ref: ImageLineRef, index: Int) -> TranscriptImageData? {
        // 読んでいる間に読み直し（reset）が入っていれば、位置は覚え直さない。
        if imageLines[itemId] != nil { imageLines[itemId] = ref }
        remember(itemId, loaded)
        return loaded.images.indices.contains(index) ? loaded.images[index] : nil
    }

    /// 画像付きの行を読み直す。位置が合わなければ uuid で探し直す（ファイル全体を走査しうるので actor の外で呼ぶ）。
    static func loadImages(path: String, ref: ImageLineRef) -> (DecodedImages, ImageLineRef)? {
        var o = lineAt(path: path, offset: ref.offset, length: ref.length)
        var found = ref
        if !TranscriptFormat.isImageLine(o, uuid: ref.uuid) {
            // uuid が無い行は取り違えを避けて諦める。
            guard let uuid = ref.uuid, let hit = findLine(path: path, uuid: uuid) else { return nil }
            found = ImageLineRef(offset: hit.offset, length: hit.length, uuid: uuid)
            o = hit.object
        }
        let content = ((o as? [String: Any])?["message"] as? [String: Any])?["content"]
        let images = TranscriptFormat.imageBlocks(content).map { TranscriptFormat.imageData(of: content, index: $0.index) }
        return (DecodedImages(images: images, bytes: images.reduce(0) { $0 + ($1?.data.count ?? 0) }), found)
    }

    private func remember(_ itemId: String, _ value: DecodedImages) {
        guard value.bytes <= Self.maxDecodedBytes, decoded[itemId] == nil else { return }
        decoded[itemId] = value
        decodedOrder.append(itemId)
        decodedBytes += value.bytes
        while decodedOrder.count > Self.maxDecodedLines || decodedBytes > Self.maxDecodedBytes, let oldest = decodedOrder.first {
            decodedOrder.removeFirst()
            decodedBytes -= decoded.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }

    private static func lineAt(path: String, offset: Int, length: Int) -> Any? {
        guard length > 0, length <= TranscriptFormat.maxImageLineBytes,
              let bytes = Bytes.read(path, offset: offset, length: length) else { return nil }
        return JSONLoose.object(bytes)
    }

    /// uuid の行をバイト位置付きで探す。
    private static func findLine(path: String, uuid: String) -> (object: Any, offset: Int, length: Int)? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let needle = Array(#""uuid":"\#(uuid)""#.utf8)
        var parts: [UInt8] = []
        var skip = false // 上限を超えた行は末尾まで読み飛ばす
        var lineStart = 0
        var position = 0
        var buf = [UInt8](repeating: 0, count: TranscriptFormat.chunkBytes)
        while true {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(position)) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var start = 0
            for i in 0..<n where buf[i] == 0x0A {
                if !skip {
                    let bytes = parts + buf[start..<i]
                    if Bytes.contains(bytes, needle), let o = JSONLoose.object(bytes), TranscriptFormat.isImageLine(o, uuid: uuid) {
                        return (o, lineStart, bytes.count)
                    }
                }
                parts = []
                skip = false
                lineStart = position + i + 1
                start = i + 1
            }
            if start < n {
                if !skip {
                    parts.append(contentsOf: buf[start..<n])
                    if parts.count > TranscriptFormat.maxImageLineBytes {
                        skip = true
                        parts = []
                    }
                }
            }
            position += n
        }
        return nil
    }

    /// `after` より後の要素。知らない id なら全件を返して reset を立てる。
    func since(_ after: String?) -> (items: [TranscriptItem], reset: Bool) {
        guard let after else { return (items, false) }
        guard let at = index[after] else { return (items, true) }
        return (Array(items[(at + 1)...]), false)
    }
}
