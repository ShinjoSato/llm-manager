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

    public var isDefault: Bool { variants.isEmpty && (locale ?? "").isEmpty }

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

    public init(displayName: String?, destination: RenderedDestination?, renderedAt: Date, sourceLineNumber: Int?,
                supportedVariants: [String: [String]], supportedLocalizations: [String]) {
        self.displayName = displayName
        self.destination = destination
        self.renderedAt = renderedAt
        self.sourceLineNumber = sourceLineNumber
        self.supportedVariants = supportedVariants
        self.supportedLocalizations = supportedLocalizations
    }

    public init(result: RenderPreviewResult, renderedAt: Date) {
        self.init(displayName: result.displayName, destination: result.renderedDestination, renderedAt: renderedAt,
                  sourceLineNumber: result.sourceLineNumber,
                  supportedVariants: result.supportedPreviewVariantOverrides ?? [:],
                  supportedLocalizations: result.supportedLocalizations ?? [])
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
        let millis = sourceModified.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
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

    /// Xcode が書いた PNG を写し、同じ指定の古い版を消す。
    @discardableResult
    public static func store(snapshotAt source: URL, info: PreviewSnapshotInfo, key: PreviewCacheKey,
                             base: URL = baseDirectory) throws -> URL {
        let data = try Data(contentsOf: source)
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
}
