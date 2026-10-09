import Foundation

/// プロジェクト配下で見つけた画像ファイル。
public struct ProjectImage: Equatable, Sendable, Identifiable {
    /// プロジェクトからの相対パス。
    public var relativePath: String
    /// 絶対パス（リンクなら実体ではなくリンクの場所）。
    public var path: String
    public var fileSize: Int
    public var modified: Date?

    public var id: String { relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }

    public init(relativePath: String, path: String, fileSize: Int, modified: Date? = nil) {
        self.relativePath = relativePath
        self.path = path
        self.fileSize = fileSize
        self.modified = modified
    }
}

/// 同じフォルダの画像のまとまり。
public struct ProjectImageGroup: Equatable, Sendable, Identifiable {
    /// フォルダのプロジェクトからの相対パス（直下は `.`。`.xcassets` の中はその `.xcassets` でまとめる）。
    public var relativePath: String
    public var images: [ProjectImage]

    public var id: String { relativePath }

    public init(relativePath: String, images: [ProjectImage]) {
        self.relativePath = relativePath
        self.images = images
    }
}

/// 走査の結果。
public struct ProjectImageScan: Equatable, Sendable {
    public var groups: [ProjectImageGroup]
    /// 件数かフォルダ数の上限で打ち切った。
    public var truncated: Bool

    public var count: Int { groups.reduce(0) { $0 + $1.images.count } }

    public init(groups: [ProjectImageGroup], truncated: Bool) {
        self.groups = groups
        self.truncated = truncated
    }
}

/// プロジェクト配下の画像の走査とフォルダごとのまとめ。
public enum ProjectImages {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "tif", "bmp", "ico"]
    /// 探す深さ（プロジェクト直下を 0 として、このフォルダの中までは見る）。
    public static let maxDepth = 8
    public static let maxCount = 2000
    /// 読むフォルダ数の上限（画像が無くても巨大なツリーで走査が終わらないのを防ぐ）。
    public static let maxDirectories = 20_000
    /// 中を見ないフォルダ（依存・ビルドの成果物）。隠しフォルダも見ない。
    public static let skipped: Set<String> = SiteLocator.skipped.union([".build", ".swiftpm"])
    /// 大文字小文字を区別しないファイルシステムで `Build/` 等を素通りさせないため、小文字でも照合する。
    private static let skippedLowercased = Set(skipped.map { $0.lowercased() })

    static func isSkipped(_ name: String) -> Bool { skippedLowercased.contains(name.lowercased()) }

    public static func isImage(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 浅いフォルダから順に集め、上限に達したら打ち切る。`isCancelled` が真になればそこまでの結果を返す。
    public static func scan(projectPath: String, maxDepth: Int = maxDepth, maxCount: Int = maxCount,
                            maxDirectories: Int = maxDirectories, isCancelled: () -> Bool = { false },
                            fileManager: FileManager = .default) -> ProjectImageScan {
        var images: [ProjectImage] = []
        let realProject = FilePaths.realPath(projectPath)
        // 画面の並びと同じ順で集め、打ち切った時に残るものを表示と一致させる。
        let truncated = ProjectTree.walk(root: projectPath, maxDepth: maxDepth, maxDirectories: maxDirectories,
                                         isCancelled: isCancelled, fileManager: fileManager, descend: { !isSkipped($0) }) { entry in
            let found: ProjectImage?
            switch entry.type {
            case .typeRegular:
                found = isImage(entry.name) ? image(entry.relativePath, path: entry.path, attrs: entry.attributes) : nil
            case .typeSymbolicLink:
                // フォルダのリンクは循環しうるので辿らない。ファイルのリンクは実体がプロジェクトの中にある時だけ数える。
                guard isImage(entry.name), let realProject, let real = FilePaths.realPath(entry.path),
                      real.hasPrefix(realProject + "/"),
                      let realAttrs = try? fileManager.attributesOfItem(atPath: real),
                      realAttrs[.type] as? FileAttributeType == .typeRegular else { return true }
                found = image(entry.relativePath, path: entry.path, attrs: realAttrs)
            default:
                found = nil
            }
            guard let found else { return true }
            guard images.count < maxCount else { return false }
            images.append(found)
            return true
        }
        return ProjectImageScan(groups: grouped(images), truncated: truncated)
    }

    private static func image(_ relativePath: String, path: String, attrs: [FileAttributeKey: Any]) -> ProjectImage {
        ProjectImage(relativePath: relativePath, path: path,
                     fileSize: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                     modified: attrs[.modificationDate] as? Date)
    }

    /// フォルダごとにまとめ、浅い順 → 名前順に並べる。中は名前順。
    public static func grouped(_ images: [ProjectImage]) -> [ProjectImageGroup] {
        var buckets: [String: [ProjectImage]] = [:]
        for image in images { buckets[groupPath(for: image.relativePath), default: []].append(image) }
        return buckets.map { path, members in
            ProjectImageGroup(relativePath: path, images: members.sorted { naturalOrder($0.relativePath, $1.relativePath) })
        }.sorted { a, b in
            let da = depth(of: a.relativePath), db = depth(of: b.relativePath)
            if da != db { return da < db }
            return naturalOrder(a.relativePath, b.relativePath)
        }
    }

    /// 画像の相対パスからグループのフォルダ。`.xcassets` の中（imageset / appiconset 等）はその `.xcassets` にまとめる。
    static func groupPath(for relativePath: String) -> String {
        let dirs = relativePath.split(separator: "/").dropLast().map(String.init)
        guard !dirs.isEmpty else { return "." }
        if let index = dirs.firstIndex(where: { $0.lowercased().hasSuffix(".xcassets") }) {
            return dirs[...index].joined(separator: "/")
        }
        return dirs.joined(separator: "/")
    }

    static func depth(of groupPath: String) -> Int {
        groupPath == "." ? 0 : groupPath.split(separator: "/").count
    }

    /// 数字を自然順に並べる（img2 < img10）。
    static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}

/// プロジェクトの下を浅いフォルダから自然順で辿る（「画像」と「iPhone のプレビュー」の走査で共通）。
enum ProjectTree {
    struct Entry {
        let name: String
        let path: String
        let relativePath: String
        let type: FileAttributeType
        let attributes: [FileAttributeKey: Any]
    }

    /// 隠しファイルは見ず、`descend` の通るフォルダだけ降りてフォルダ以外を `visit` に渡す。`visit` の false かフォルダ数の上限で打ち切ったら true。
    static func walk(root: String, maxDepth: Int, maxDirectories: Int, isCancelled: () -> Bool, fileManager: FileManager,
                     descend: (String) -> Bool, visit: (Entry) -> Bool) -> Bool {
        var queue: [(relative: String, depth: Int)] = [(".", 0)]
        var head = 0
        while head < queue.count {
            if isCancelled() { return false }
            if head >= maxDirectories { return true }
            let (relative, depth) = queue[head]
            head += 1
            let dir = SiteLocator.absolute(relative, in: root)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted(by: ProjectImages.naturalOrder) where !name.hasPrefix(".") {
                let child = (dir as NSString).appendingPathComponent(name)
                let childRelative = relative == "." ? name : "\(relative)/\(name)"
                guard let attrs = try? fileManager.attributesOfItem(atPath: child),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    if depth < maxDepth, descend(name) { queue.append((childRelative, depth + 1)) }
                } else if !visit(Entry(name: name, path: child, relativePath: childRelative, type: type, attributes: attrs)) {
                    return true
                }
            }
        }
        return false
    }
}
