import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 入力欄に添えた画像・ファイル 1 つ。
public struct Attachment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Claude Code に画像として取り込ませるもの（一時保存先のコピー）。
        case image
        /// パスを本文に書いて Claude に読ませるもの（元の場所のまま）。
        case file
    }

    public let id: UUID
    public let kind: Kind
    /// 送るパス（絶対パス）。
    public let path: String
    /// チップに出す名前。
    public let name: String
    /// 元のファイル（クリップボードの画像なら nil）。同じものを二重に添えないために使う。
    public let sourcePath: String?

    public init(id: UUID = UUID(), kind: Kind, path: String, name: String, sourcePath: String?) {
        self.id = id
        self.kind = kind
        self.path = path
        self.name = name
        self.sourcePath = sourcePath
    }
}

/// 添付の入手元（ファイル選択・ペースト・ドロップ）。
public enum AttachmentSource: Sendable, Equatable {
    case file(URL)
    /// クリップボード・ドロップの画像（形式は問わない。取り込み時に必要なら PNG に変換する）。
    case imageData(Data, name: String)

    /// 元のファイルのパス（同じものを二重に添えないために使う）。
    public var sourcePath: String? {
        if case .file(let url) = self { return url.standardizedFileURL.path }
        return nil
    }
}

/// 送る形への組み立て。値は Claude Code v2.1.286 の貼り付け処理（`[Image #N]` への変換）で確認。
public enum AttachmentFormat {
    /// 貼り付けたパスを画像として取り込む拡張子（TUI の判定 `/\.(png|jpe?g|gif|webp)$/i`）。
    public static let pasteableImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// PNG に変換してから画像として渡す拡張子。
    public static let convertibleImageExtensions: Set<String> = ["heic", "heif", "tif", "tiff", "bmp"]
    /// 本文の末尾に添えるパスの見出し。
    public static let listHeader = "添付:"
    /// 画像の取り込み（TUI がファイルを読んで `[Image #N]` を入れる）は非同期で、その間の Enter は捨てられるので、印が出るまで待つ。
    public static let imageIngestTimeout: TimeInterval = 5
    public static let imageIngestPollInterval: TimeInterval = 0.1

    /// 送る中身。`imagePaste` は本文とは別の 1 回の貼り付けで送る（同じ貼り付けに画像パスがあると TUI が本文を行に割るため）。
    public struct Outgoing: Sendable, Equatable {
        /// 画像のパスを空白で区切ったもの（貼り付け用・括弧なし）。無ければ nil。
        public var imagePaste: String?
        public var imageCount: Int
        /// 画像として貼る添付のパス（`imagePaste` に入れた順）。
        public var imagePaths: [String] = []
        /// 本文（ファイルのパスの一覧を含む）。空なら送らない。
        public var body: String

        public var isEmpty: Bool { imagePaste == nil && body.isEmpty }
    }

    /// `pasteImages` が false（貼り付けモードでない端末・伝言）なら画像もパスの一覧に入れる。
    public static func outgoing(text: String, attachments: [Attachment], pasteImages: Bool) -> Outgoing {
        var tokens: [String] = []
        var pasted: [String] = []
        var listed: [String] = []
        for attachment in attachments {
            if pasteImages, attachment.kind == .image, let token = pasteToken(attachment.path) {
                tokens.append(token)
                pasted.append(attachment.path)
            } else {
                listed.append(attachment.path)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !trimmed.isEmpty { parts.append(trimmed) }
        if !listed.isEmpty { parts.append(([listHeader] + listed.map(quoted)).joined(separator: "\n")) }
        return Outgoing(imagePaste: tokens.isEmpty ? nil : tokens.joined(separator: " "),
                        imageCount: tokens.count,
                        imagePaths: pasted,
                        body: parts.joined(separator: "\n\n"))
    }

    /// 貼り付けで画像として取り込まれる形のパス。取り込めない形なら nil。
    /// TUI は貼り付けを「空白 + /」と改行で区切り、各片の前後の引用符を外し `\x` を `x` に戻してから拡張子を見る。
    static func pasteToken(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains(" /"), !path.contains("\\"),
              path == path.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        guard pasteableImageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        var token = ""
        for character in path {
            if character == "\"" || character == "'" || character.isWhitespace { token.append("\\") }
            token.append(character)
        }
        return token
    }

    /// 本文に書くパス。空白や引用符を含む時だけ引用符で囲む。
    static func quoted(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { return path }
        return "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 端末の入力欄に出ている画像の印（`[Image #N]`）の数。取り込みが済んだかを見るのに使う。
    /// 入力欄は折り返しで行が割れ（`InputBox.text` は行ごとに詰めて改行でつなぐ）、印の途中で切れることがあるので空白を除いて数える。
    public static func imageTokenCount(in text: String) -> Int {
        text.filter { !$0.isWhitespace }.components(separatedBy: "[Image#").count - 1
    }
}

/// ペースト・ドロップの中身から添付を拾う。
public enum AttachmentPasteboard {
    /// 画像として受ける型（ドラッグ先の登録用）。
    public static var imageTypes: [NSPasteboard.PasteboardType] {
        NSImage.imageTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
    }

    /// `sources` が空でないか（データを読まずに型だけで見る。ドラッグ中に何度も呼ばれるため）。
    public static func canAttach(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pasteboard.availableType(from: [.string]) != nil { return false }
        return imageType(in: pasteboard) != nil
    }

    /// ファイル URL か、文字列の無い画像（元の形式のまま）を返す。添付にしないなら空。
    /// 文字列を含むコピーは画像表現も載ることがあるので文字として貼る。変換は重いので取り込み（`ingest`）に任せる。
    public static func sources(in pasteboard: NSPasteboard, imageName: String = "貼り付けた画像") -> [AttachmentSource] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map { .file($0) } }
        if pasteboard.availableType(from: [.string]) != nil { return [] }
        guard let type = imageType(in: pasteboard), let data = pasteboard.data(forType: type) else { return [] }
        return [.imageData(data, name: imageName)]
    }

    /// 載っている画像の型。PNG があればそれを優先する（変換が要らないため）。
    static func imageType(in pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        if pasteboard.availableType(from: [.png]) != nil { return .png }
        return pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    }
}

/// 添付の一時保存先（`~/Library/Caches/claude-deck/attachments/`）。ディレクトリ 0700・ファイル 0600。
public struct AttachmentStore: Sendable {
    public let directory: URL
    /// これより古い一時ファイルは起動時に消す。
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    /// 画像 1 件の大きさの上限（写しと変換の負荷、Claude に渡す画像の大きさを抑える）。
    public static let maxImageBytes = 20 * 1024 * 1024

    public init(directory: URL = AttachmentStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        DeckPaths.caches.appendingPathComponent("attachments", isDirectory: true)
    }

    public enum StoreError: LocalizedError, Equatable {
        case unreadable(String)
        case tooLarge(String, bytes: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "「\(name)」を読み込めませんでした"
            case .tooLarge(let name, let bytes):
                let limit = AttachmentStore.maxImageBytes / (1024 * 1024)
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "「\(name)」は大きすぎるため添付しませんでした（\(size)。画像は \(limit)MB まで）"
            }
        }
    }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// 画像は一時保存先へ写す（元が消える・パスに空白がある・TUI が読めない形式でも取り込めるように）。それ以外は元のパスのまま。
    /// 写しと変換で重くなりうるので、メインスレッドから呼ばない。
    public func ingest(_ source: AttachmentSource) throws -> Attachment {
        switch source {
        case .imageData(let data, let name):
            guard data.count <= Self.maxImageBytes else { throw StoreError.tooLarge(name, bytes: data.count) }
            guard let image = CGImageSourceCreateWithData(data as CFData, nil) else { throw StoreError.unreadable(name) }
            if let ext = Self.pasteableExtension(of: image) {
                let url = try write(data, extension: ext)
                return Attachment(kind: .image, path: url.path, name: name, sourcePath: nil)
            }
            guard let png = Self.pngData(from: image) else { throw StoreError.unreadable(name) }
            let url = try write(png, extension: "png")
            return Attachment(kind: .image, path: url.path, name: name, sourcePath: nil)
        case .file(let original):
            let url = original.standardizedFileURL
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw StoreError.unreadable(name) }
            let ext = url.pathExtension.lowercased()
            let isPasteable = AttachmentFormat.pasteableImageExtensions.contains(ext)
            guard !isDirectory.boolValue, isPasteable || AttachmentFormat.convertibleImageExtensions.contains(ext) else {
                return Attachment(kind: .file, path: url.path, name: name, sourcePath: url.path)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= Self.maxImageBytes else { throw StoreError.tooLarge(name, bytes: size) }
            if isPasteable {
                let copy = try copy(url, extension: ext == "jpeg" ? "jpg" : ext, name: name)
                return Attachment(kind: .image, path: copy.path, name: name, sourcePath: url.path)
            }
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), let png = Self.pngData(from: image) else {
                // 変換できない画像は TUI も読めないので、パスで渡して Claude に任せる。
                return Attachment(kind: .file, path: url.path, name: name, sourcePath: url.path)
            }
            let converted = try write(png, extension: "png")
            return Attachment(kind: .image, path: converted.path, name: name, sourcePath: url.path)
        }
    }

    /// 外した添付の一時ファイルを消す。一時保存先の外（元のファイル）には触らない。
    public func discard(_ attachment: Attachment) {
        guard contains(attachment.path) else { return }
        try? FileManager.default.removeItem(atPath: attachment.path)
    }

    func contains(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent().path == directory.standardizedFileURL.path
    }

    /// `maxAge` より古い一時ファイルを消し、消した数を返す。
    @discardableResult
    public func sweep(now: Date = Date(), maxAge: TimeInterval = AttachmentStore.maxAge) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    private func newFileURL(extension ext: String) throws -> URL {
        try prepare()
        return directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    private func copy(_ original: URL, extension ext: String, name: String) throws -> URL {
        let url = try newFileURL(extension: ext)
        do {
            try FileManager.default.copyItem(at: original, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw StoreError.unreadable(name)
        }
        return url
    }

    private func write(_ data: Data, extension ext: String) throws -> URL {
        let url = try newFileURL(extension: ext)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    /// TUI がそのまま取り込める形式なら、その拡張子。
    static func pasteableExtension(of image: CGImageSource) -> String? {
        guard let identifier = CGImageSourceGetType(image) as String?, let type = UTType(identifier) else { return nil }
        let candidates: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.webP, "webp")]
        return candidates.first { type.conforms(to: $0.0) }?.1
    }

    /// チップに出す縮小画像。読めなければ nil。
    public static func thumbnail(of path: String, maxPixelSize: Int = 128) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary)
    }

    static func pngData(from image: CGImageSource) -> Data? {
        guard let frame = CGImageSourceCreateImageAtIndex(image, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// 送信の結末（画像の取り込み待ち・Enter の直前の判定を経た後）。
public enum SendCompletion: Sendable, Equatable {
    /// Enter まで送った。
    case submitted
    /// 画像だけ貼り、本文を貼る前にやめた（端末の入力欄には画像の印だけが残る）。
    case abortedBeforeBody(InputBlock)
    /// 本文を貼った後、Enter を押さずにやめた（本文が端末の入力欄に残る）。
    case abortedAfterBody(InputBlock)
    /// 貼った本文が端末の入力欄に入らなかったので Enter を送らなかった。`imagesPasted` は画像の印を先に貼ったか。
    case notPasted(imagesPasted: Bool)
    /// 待っている間に端末が無くなった。
    case ended

    /// 本文と添付を入力欄に戻すか（端末に本文が入っていない時だけ。戻すと二重に送ることになるため）。
    public var restoresDraft: Bool {
        switch self {
        case .abortedBeforeBody, .notPasted: return true
        case .submitted, .abortedAfterBody, .ended: return false
        }
    }

    /// 取りやめた時に出す案内。送れた・端末が無くなった時は nil。
    public var notice: String? {
        switch self {
        case .submitted, .ended:
            return nil
        case .abortedBeforeBody(let block):
            return "送信の途中で\(Self.blockName(block))が出たため、本文を貼る前に取りやめました。"
                + "端末側の入力欄には画像（[Image #N]）だけが残っています。本文と添付はこの入力欄に戻しました。"
                + "\(Self.answerHint(block))、そのまま送り直すと画像が二重に付きます（端末側の入力欄の画像はターミナルで消せます）。"
        case .notPasted(let imagesPasted):
            return Self.notPastedNotice + "Enter は押さず、本文と添付はこの入力欄に戻しました。"
                + (imagesPasted ? "端末側の入力欄には画像（[Image #N]）が残っているので、そのまま送り直すと画像が二重に付きます。" : "")
                + "ターミナルでダイアログを閉じてから送り直してください。" + Self.lateNotice
        case .abortedAfterBody(let block):
            // 入力欄に入った本文を安全に消すキーが無い（Esc はメニューの取り消しになる）ので、下書きには戻さず二重送信を避ける。
            return "送信の途中で\(Self.blockName(block))が出たため、本文を貼った後、Enter を押さずに取りやめました。"
                + "端末側の入力欄に本文が残っています。\(Self.answerHint(block))ここから送ると、残っている本文とつながって送られます。"
        }
    }

    /// iPhone からの送信の結末（mac の入力欄には戻さないので、戻した旨は書かない）。送れたなら nil。
    public var remoteNotice: String? {
        switch self {
        case .submitted:
            return nil
        case .ended:
            return "claude が終了したため送れませんでした。"
        case .abortedBeforeBody(let block):
            return "送信の途中で\(Self.blockName(block))が出たため、本文を貼る前に取りやめました。"
        case .abortedAfterBody(let block):
            return "送信の途中で\(Self.blockName(block))が出たため、本文を貼った後、Enter を押さずに取りやめました。"
                + "端末側の入力欄に本文が残っています。\(Self.answerHint(block))送ると、残っている本文とつながって送られます。"
        case .notPasted:
            return Self.notPastedNotice + "Enter は押していません。" + Self.lateNotice
        }
    }

    static let notPastedNotice = "端末の入力欄に入りませんでした（ダイアログ等が開いている可能性があります）。"
    static let lateNotice = "遅れて端末に入った場合は、次の送信の前に残りとして知らせます。"

    static func blockName(_ block: InputBlock) -> String {
        switch block {
        case .permission: return "権限の確認"
        case .menu: return "選択肢"
        }
    }

    private static func answerHint(_ block: InputBlock) -> String {
        block == .permission ? "権限の確認に答えた後に" : "上の選択肢に答えた後に"
    }
}

/// 貼り付けが端末の入力欄に入ったかの判定。長文は `[Pasted text #1 …]` に畳まれるので、本文との一致ではなく変化で見る。
public enum PasteCheck {
    public enum Verdict: Sendable, Equatable {
        case pasted
        /// 入力欄が空か、貼る前から変わっていない。
        case missing
        /// 入力欄を読めない（確かめられないので従来どおり送る）。
        case unknown
    }

    public static let pollInterval: TimeInterval = 0.1

    /// 最初の確認（`PTYInput.submitDelay` 後）で入っていない時に、描き替えを待つ時間。長文ほど取り込みが遅いので延ばす。
    public static func extraWait(bodyLength: Int) -> TimeInterval {
        min(1.0 + Double(bodyLength) / 2000, 4.0)
    }

    /// `before` は貼る前、`after` は今の入力欄の文字（`InputBox.text`。読めなければ nil）、`body` は貼った本文。
    public static func judge(before: String?, after: String?, body: String) -> Verdict {
        guard let after else { return .unknown }
        // 例文と同じ形の本文は入っても空欄と見分けられないので、確かめずに送る。
        let text = plainText(body)
        if !text.contains("\n"), InputBox.isPlaceholder(text) { return .unknown }
        if after.isEmpty || after == before { return .missing }
        return .pasted
    }

    static func plainText(_ body: String) -> String {
        body.replacingOccurrences(of: PTYInput.pasteStart, with: "").replacingOccurrences(of: PTYInput.pasteEnd, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 取りやめた送信の残りが端末の入力欄にあるかもしれない時の、次の送信の扱い。
public enum LeftoverCheck: Sendable, Equatable {
    case none
    /// 残りがあれば 1 回だけ知らせる（未知の薄字表示を本文と誤認しても、もう一度送れば送れる）。
    case warnOnce
    /// 貼り付けが入らなかった送信の後。遅れて入った本文と戻した本文が二重にならないよう、入力欄が貼る前（`baseline`）か空と確かめるまで送らない。
    case untilClear(baseline: String)

    public enum Decision: Sendable, Equatable {
        case send
        /// `strict` は確かめられるまで何度でも止める側。
        case refuse(strict: Bool)
    }

    /// 今の入力欄（読めなければ nil）から、送るかと次の状態を決める。
    public func decide(box: String?) -> (Decision, next: LeftoverCheck) {
        switch self {
        case .none:
            return (.send, .none)
        case .warnOnce:
            // 入力欄が読めない時は残りを確かめられないが、くっつく害は小さいので送る（印は残す）。
            guard let box else { return (.send, .warnOnce) }
            return (box.isEmpty ? .send : .refuse(strict: false), .none)
        case .untilClear(let baseline):
            guard let box, box.isEmpty || box == baseline else { return (.refuse(strict: true), self) }
            return (.send, .none)
        }
    }
}

/// 取りやめた送信の本文・添付を入力欄に戻す時の合わせ方。
public enum ComposerRestore {
    /// 戻す本文を、その間に書き足した下書きの前に置く（書いた順に並べる）。
    public static func draft(restoring sent: String, current: String) -> String {
        let sentTrimmed = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentTrimmed.isEmpty else { return current }
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sent }
        return sent + "\n" + current
    }

    /// 戻す添付を前に置き、その間に添えた同じ元ファイルは外す。外したものは `dropped` に返す（一時ファイルを消すため）。
    public static func attachments(restoring sent: [Attachment], current: [Attachment]) -> (merged: [Attachment], dropped: [Attachment]) {
        let sources = Set(sent.compactMap(\.sourcePath))
        let duplicate: (Attachment) -> Bool = { $0.sourcePath.map(sources.contains) ?? false }
        return (sent + current.filter { !duplicate($0) }, current.filter(duplicate))
    }
}
