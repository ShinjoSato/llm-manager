import Foundation

/// プロジェクトの LP（Next.js の静的書き出し等）の場所。
public struct SiteLocation: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// 設定の `site` で指定された。
        case configured
        /// 自動で見つけた。
        case detected
    }

    /// プロジェクトからの相対パス（`.` は直下）。
    public var relativePath: String
    /// サイトのフォルダ（絶対パス）。
    public var root: String
    public var source: Source

    /// 静的書き出しの置き場所（配信するのはこの配下だけ）。
    public var exportDir: String { (root as NSString).appendingPathComponent(SiteLocator.exportDirName) }
    /// 書き出しのトップ。更新時刻とサムネイルの撮り直しの目安にする。
    public var exportIndex: String { (exportDir as NSString).appendingPathComponent("index.html") }

    public init(relativePath: String, root: String, source: Source) {
        self.relativePath = relativePath
        self.root = root
        self.source = source
    }
}

/// 探した結果。指定が使えない時は理由を持ち、自動の候補が複数あれば全部持つ。
public struct SiteLookup: Equatable, Sendable {
    public var location: SiteLocation?
    /// 自動で見つけた場所（相対パス・良さそうな順）。
    public var candidates: [String]
    /// 設定の指定が使えない理由。
    public var problem: String?

    public init(location: SiteLocation?, candidates: [String], problem: String? = nil) {
        self.location = location
        self.candidates = candidates
        self.problem = problem
    }
}

/// LP の場所の検出と、設定の相対パスの検証。
public enum SiteLocator {
    public static let exportDirName = "out"
    /// 探す深さ（プロジェクト直下を 0 として）。
    static let maxDepth = 2
    /// 中を見ないフォルダ（依存・ビルドの成果物）。隠しフォルダも見ない。
    static let skipped: Set<String> = ["node_modules", ".next", "out", "build", "dist", "Pods", "DerivedData", "vendor"]
    static let configNames = ["next.config.js", "next.config.mjs", "next.config.ts", "next.config.cjs"]

    public enum Normalized: Equatable {
        case success(String)
        case failure(String)

        public var failure: String? {
            if case .failure(let reason) = self { return reason }
            return nil
        }

        public var path: String? {
            if case .success(let path) = self { return path }
            return nil
        }
    }

    /// 相対パスを `site` / `.` の形にそろえる。絶対パス・`~`・`..` を含むもの（プロジェクトの外を指しうる）は通さない。
    public static func normalizedRelativePath(_ raw: String) -> Normalized {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure("サイトの場所を入れてください（プロジェクト直下なら .）") }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return .failure("サイトの場所はプロジェクトからの相対パスにしてください") }
        if trimmed.contains("\\") || trimmed.contains("\0") { return .failure("サイトの場所に使えない文字が入っています") }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.contains("..") { return .failure("サイトの場所はプロジェクトの外を指せません") }
        return .success(parts.isEmpty ? "." : parts.joined(separator: "/"))
    }

    /// 設定の指定を優先し、無ければ自動で探す。
    public static func lookup(project: ManagedProject, fileManager: FileManager = .default) -> SiteLookup {
        lookup(projectPath: project.path, configured: project.site?.path, fileManager: fileManager)
    }

    public static func lookup(projectPath: String, configured: String?, fileManager: FileManager = .default) -> SiteLookup {
        let found = candidates(projectPath: projectPath, fileManager: fileManager)
        guard let configured else {
            let location = found.first.map { SiteLocation(relativePath: $0, root: absolute($0, in: projectPath), source: .detected) }
            return SiteLookup(location: location, candidates: found)
        }
        switch normalizedRelativePath(configured) {
        case .failure(let reason):
            return SiteLookup(location: nil, candidates: found, problem: reason)
        case .success(let relative):
            let root = absolute(relative, in: projectPath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                return SiteLookup(location: nil, candidates: found, problem: "指定のフォルダ（\(relative)）が見つかりません")
            }
            // シンボリックリンクでプロジェクトの外へ出ていないかを実体で確かめる。
            guard let realProject = realPath(projectPath), let realRoot = realPath(root),
                  realRoot == realProject || realRoot.hasPrefix(realProject + "/") else {
                return SiteLookup(location: nil, candidates: found, problem: "指定のフォルダ（\(relative)）がプロジェクトの外を指しています")
            }
            return SiteLookup(location: SiteLocation(relativePath: relative, root: root, source: .configured), candidates: found)
        }
    }

    /// プロジェクト直下と浅いサブフォルダから LP らしい場所を探す（書き出し済み → 浅い → 名前の順）。
    public static func candidates(projectPath: String, fileManager: FileManager = .default) -> [String] {
        var found: [(relative: String, depth: Int, exported: Bool)] = []
        var queue: [(relative: String, depth: Int)] = [(".", 0)]
        while !queue.isEmpty {
            let (relative, depth) = queue.removeFirst()
            let dir = absolute(relative, in: projectPath)
            if isSite(dir, fileManager: fileManager) {
                let exported = fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent("\(exportDirName)/index.html"))
                found.append((relative, depth, exported))
                // サイトの中の入れ子（example 等）は別のサイトとして数えない。
                continue
            }
            guard depth < maxDepth, let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && !skipped.contains(name) {
                let child = (dir as NSString).appendingPathComponent(name)
                // シンボリックリンクのフォルダは辿らない（外へ出たり循環したりしないため）。
                guard let attrs = try? fileManager.attributesOfItem(atPath: child),
                      attrs[.type] as? FileAttributeType == .typeDirectory else { continue }
                queue.append((relative == "." ? name : "\(relative)/\(name)", depth + 1))
            }
        }
        return found.sorted { a, b in
            if a.exported != b.exported { return a.exported }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.relative < b.relative
        }.map(\.relative)
    }

    /// Next.js の設定があるか、package.json と書き出し済みのトップがある。
    static func isSite(_ dir: String, fileManager: FileManager) -> Bool {
        let has = { (name: String) in fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) }
        if configNames.contains(where: has) { return true }
        return has("package.json") && has("\(exportDirName)/index.html")
    }

    public static func absolute(_ relative: String, in projectPath: String) -> String {
        relative == "." ? projectPath : (projectPath as NSString).appendingPathComponent(relative)
    }

    /// 選んだフォルダをプロジェクトからの相対パスにする。外なら nil。
    public static func relativePath(of path: String, in projectPath: String) -> String? {
        guard let realProject = realPath(projectPath), let real = realPath(path) else { return nil }
        if real == realProject { return "." }
        guard real.hasPrefix(realProject + "/") else { return nil }
        return String(real.dropFirst(realProject.count + 1))
    }

    /// シンボリックリンクを解いた実体のパス（無ければ nil）。
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 書き出しのトップの更新時刻（無い・書き出しがサイトの外を指すなら nil）。
    public static func exportModified(_ location: SiteLocation, fileManager: FileManager = .default) -> Date? {
        guard isExportInside(exportDir: location.exportDir) else { return nil }
        return (try? fileManager.attributesOfItem(atPath: location.exportIndex))?[.modificationDate] as? Date
    }

    /// 書き出しのフォルダ（`out` がリンクでも）の実体がサイトのフォルダの実体の中にあるか。
    public static func isExportInside(exportDir: String) -> Bool {
        let siteRoot = (exportDir as NSString).deletingLastPathComponent
        guard let realSite = realPath(siteRoot), let realExport = realPath(exportDir) else { return false }
        return realExport.hasPrefix(realSite + "/")
    }
}
