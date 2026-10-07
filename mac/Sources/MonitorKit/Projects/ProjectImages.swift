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
    /// 件数の上限で打ち切った。
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
    /// 中を見ないフォルダ（依存・ビルドの成果物）。隠しフォルダも見ない。
    public static let skipped: Set<String> = SiteLocator.skipped.union([".build", ".swiftpm"])

    public static func isImage(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 浅いフォルダから順に集め、上限に達したら打ち切る。
    public static func scan(projectPath: String, maxDepth: Int = maxDepth, maxCount: Int = maxCount,
                            fileManager: FileManager = .default) -> ProjectImageScan {
        var images: [ProjectImage] = []
        var truncated = false
        let realProject = SiteLocator.realPath(projectPath)
        var queue: [(relative: String, depth: Int)] = [(".", 0)]
        scanning: while !queue.isEmpty {
            let (relative, depth) = queue.removeFirst()
            let dir = SiteLocator.absolute(relative, in: projectPath)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let child = (dir as NSString).appendingPathComponent(name)
                let childRelative = relative == "." ? name : "\(relative)/\(name)"
                guard let attrs = try? fileManager.attributesOfItem(atPath: child),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                let found: ProjectImage?
                switch type {
                case .typeDirectory:
                    if depth < maxDepth, !skipped.contains(name) { queue.append((childRelative, depth + 1)) }
                    found = nil
                case .typeRegular:
                    found = isImage(name) ? image(childRelative, path: child, attrs: attrs) : nil
                case .typeSymbolicLink:
                    // フォルダのリンクは循環しうるので辿らない。ファイルのリンクは実体がプロジェクトの中にある時だけ数える。
                    guard isImage(name), let realProject, let real = SiteLocator.realPath(child),
                          real.hasPrefix(realProject + "/"),
                          let realAttrs = try? fileManager.attributesOfItem(atPath: real),
                          realAttrs[.type] as? FileAttributeType == .typeRegular else { continue }
                    found = image(childRelative, path: child, attrs: realAttrs)
                default:
                    found = nil
                }
                guard let found else { continue }
                if images.count >= maxCount {
                    truncated = true
                    break scanning
                }
                images.append(found)
            }
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
            ProjectImageGroup(relativePath: path, images: members.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            })
        }.sorted { a, b in
            let da = depth(of: a.relativePath), db = depth(of: b.relativePath)
            if da != db { return da < db }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
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
}
