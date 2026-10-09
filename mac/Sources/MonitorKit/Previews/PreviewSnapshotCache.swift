import CryptoKit
import Foundation

/// 描く 1 件の指定（どのファイルの何番目を、どの切り替えで）。
public struct PreviewRenderRequest: Hashable, Sendable {
    /// 走査の起点からの相対パス。
    public var relativePath: String
    public var index: Int
    /// 切り替えの組（`Color Scheme` → `Dark Appearance` 等）。空なら既定。
    public var variants: [String: String]
    public var locale: String?

    public init(relativePath: String, index: Int, variants: [String: String] = [:], locale: String? = nil) {
        self.relativePath = relativePath
        self.index = index
        self.variants = variants
        self.locale = locale
    }

    /// ファイル・番号・切り替えを並びによらず 1 本の文字列に。
    var slotText: String {
        let pairs = variants.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(relativePath)|\(index)|\(pairs)|\(locale ?? "")"
    }
}

/// 描いた絵に添えて残すこと。
public struct PreviewSnapshotInfo: Codable, Equatable, Sendable {
    public var displayName: String?
    public var destination: RenderedDestination?
    public var renderedAt: Date
    public var sourceLineNumber: Int?
    public var supportedVariants: [String: [String]]
    public var supportedLocalizations: [String]
    /// 描いた時のソースの更新時刻（書き換えた後に古い絵を出さないため）。
    public var sourceModified: Date?

    public init(displayName: String?, destination: RenderedDestination?, renderedAt: Date, sourceLineNumber: Int?,
                supportedVariants: [String: [String]], supportedLocalizations: [String], sourceModified: Date? = nil) {
        self.displayName = displayName
        self.destination = destination
        self.renderedAt = renderedAt
        self.sourceLineNumber = sourceLineNumber
        self.supportedVariants = supportedVariants
        self.supportedLocalizations = supportedLocalizations
        self.sourceModified = sourceModified
    }

    public init(result: RenderPreviewResult, renderedAt: Date, sourceModified: Date? = nil) {
        self.init(displayName: result.displayName, destination: result.renderedDestination, renderedAt: renderedAt,
                  sourceLineNumber: result.sourceLineNumber,
                  supportedVariants: result.supportedPreviewVariantOverrides ?? [:],
                  supportedLocalizations: result.supportedLocalizations ?? [],
                  sourceModified: sourceModified)
    }

    /// 今のソース（走査した時の更新時刻）を描いたものか。ミリ秒でそろえて比べる（キャッシュの鍵と同じ粒度）。
    public func isCurrent(sourceModified current: Date?) -> Bool {
        Self.millis(sourceModified) == Self.millis(current)
    }

    /// Xcode が描いた定義の行が、走査した `#Preview` の行と違う（`#if` 等で番号がずれて別のプレビューを描いた可能性）。
    public func lineMismatch(expected line: Int) -> Bool {
        guard let sourceLineNumber else { return false }
        return sourceLineNumber != line
    }

    static func millis(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

/// キャッシュの鍵。プロジェクト・指定・ソースの更新時刻で決まり、ソースを書き換えれば別の鍵になる。
public struct PreviewCacheKey: Hashable, Sendable {
    public var projectId: UUID
    public var request: PreviewRenderRequest
    public var sourceModified: Date?

    public init(projectId: UUID, request: PreviewRenderRequest, sourceModified: Date?) {
        self.projectId = projectId
        self.request = request
        self.sourceModified = sourceModified
    }

    /// 同じ指定（更新時刻を問わない）の印。古い版を消す時に使う。
    public var slot: String { Self.hash(request.slotText, length: 20) }

    public var fileStem: String {
        let millis = PreviewSnapshotInfo.millis(sourceModified) ?? 0
        return "\(slot)-\(Self.hash(String(millis), length: 12))"
    }

    private static func hash(_ text: String, length: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

/// 描いた PNG と添え書きの置き場（`~/Library/Caches/claude-deck/ios-previews/<project-id>/`。0700 / 0600）。
public enum PreviewSnapshotCache {
    public static var baseDirectory: URL { DeckPaths.caches.appendingPathComponent("ios-previews", isDirectory: true) }

    public static func directory(projectId: UUID, base: URL = baseDirectory) -> URL {
        base.appendingPathComponent(projectId.uuidString.lowercased(), isDirectory: true)
    }

    public static func imageURL(_ key: PreviewCacheKey, base: URL = baseDirectory) -> URL {
        directory(projectId: key.projectId, base: base).appendingPathComponent(key.fileStem + ".png")
    }

    static func infoURL(_ key: PreviewCacheKey, base: URL) -> URL {
        directory(projectId: key.projectId, base: base).appendingPathComponent(key.fileStem + ".json")
    }

    /// 残っていれば絵の場所と添え書き。
    public static func lookup(_ key: PreviewCacheKey, base: URL = baseDirectory) -> (image: URL, info: PreviewSnapshotInfo)? {
        let image = imageURL(key, base: base)
        guard FileManager.default.fileExists(atPath: image.path),
              let info = JSONFile.read(PreviewSnapshotInfo.self, from: infoURL(key, base: base)) else { return nil }
        return (image, info)
    }

    /// 写してよい絵の大きさの上限。
    public static let maxSnapshotBytes = 50 * 1024 * 1024
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public enum SnapshotRejection: Error, Equatable, CustomStringConvertible {
        case notAbsolute
        case notPNGExtension
        case notRegularFile
        case tooLarge(Int)
        case notPNG
        case unreadable(Int32)

        public var description: String {
            switch self {
            case .notAbsolute: return "絵の場所が絶対パスではありません"
            case .notPNGExtension: return "絵が PNG の名前ではありません"
            case .notRegularFile: return "絵が通常のファイルではありません"
            case .tooLarge(let bytes): return "絵が大きすぎます（\(bytes / 1024 / 1024)MB）"
            case .notPNG: return "絵が PNG ではありません"
            case .unreadable(let code): return "絵を読めません（\(String(cString: strerror(code)))）"
            }
        }
    }

    /// Xcode が返したパスの絵を、絶対パス・リンクでない通常のファイル・`.png`・PNG の署名・大きさの上限を確かめてから読む。
    public static func readSnapshot(at path: String, maxBytes: Int = maxSnapshotBytes) throws -> Data {
        guard path.hasPrefix("/") else { throw SnapshotRejection.notAbsolute }
        guard (path as NSString).pathExtension.lowercased() == "png" else { throw SnapshotRejection.notPNGExtension }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw SnapshotRejection.unreadable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw SnapshotRejection.notRegularFile }
        // 確かめた後に差し替えられても辿らないよう、リンクを開かずに開いて同じ確かめをし直す。
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapshotRejection.unreadable(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw SnapshotRejection.unreadable(errno) }
        guard (opened.st_mode & S_IFMT) == S_IFREG else { throw SnapshotRejection.notRegularFile }
        guard opened.st_size <= off_t(maxBytes) else { throw SnapshotRejection.tooLarge(Int(opened.st_size)) }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw SnapshotRejection.tooLarge(data.count) }
        guard data.starts(with: pngSignature) else { throw SnapshotRejection.notPNG }
        return data
    }

    /// Xcode が書いた PNG を確かめて写し、同じ指定の古い版を消す。
    @discardableResult
    public static func store(snapshotPath: String, info: PreviewSnapshotInfo, key: PreviewCacheKey,
                             base: URL = baseDirectory) throws -> URL {
        let data = try readSnapshot(at: snapshotPath)
        let image = imageURL(key, base: base)
        try SecureFile.write(data, to: image)
        try SecureFile.writeJSON(info, to: infoURL(key, base: base), restrictDirectory: true)
        let dir = image.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in stale(in: names, slot: key.slot, keep: key.fileStem) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return image
    }

    /// 同じ指定で、残す版以外のファイル。
    static func stale(in names: [String], slot: String, keep: String) -> [String] {
        names.filter { name in
            name.hasPrefix(slot + "-") && (name as NSString).deletingPathExtension != keep
        }
    }

    /// 設定から消えたプロジェクトの分を片付ける。
    public static func removeProject(_ projectId: UUID, base: URL = baseDirectory) {
        try? FileManager.default.removeItem(at: directory(projectId: projectId, base: base))
    }

    /// 設定に無いプロジェクトのフォルダを消す（名前が project-id の形のものだけ）。消した id を返す。
    @discardableResult
    public static func prune(keeping projects: Set<UUID>, base: URL = baseDirectory) -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        var removed: [UUID] = []
        for name in names {
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased(), !projects.contains(id) else { continue }
            removeProject(id, base: base)
            removed.append(id)
        }
        return removed.sorted { $0.uuidString < $1.uuidString }
    }
}
