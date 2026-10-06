import Foundation

/// 静的書き出しの配信で、URL のパスを書き出しのフォルダ内のファイルに引く。外へ出るもの・隠しファイルは返さない。
public enum SiteFiles {
    public enum Resolution: Equatable, Sendable {
        /// 返すファイル（実体の絶対パス）。
        case file(String)
        /// フォルダの末尾の `/` を補う（相対参照を正しく引かせるため）。
        case redirect(String)
        case notFound
        /// 形が不正・外を指す。
        case forbidden
    }

    /// `urlPath` はクエリを除いたリクエストのパス（パーセントエンコードのまま）。
    public static func resolve(urlPath: String, root: String, fileManager: FileManager = .default) -> Resolution {
        guard urlPath.hasPrefix("/"), let decoded = urlPath.removingPercentEncoding,
              !decoded.contains("\0"), !decoded.contains("\\") else { return .forbidden }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return .forbidden }
        // .git・.env 等を書き出しに紛れ込ませても出さない。
        if parts.contains(where: { $0.hasPrefix(".") }) { return .notFound }
        guard let realRoot = SiteLocator.realPath(root), isDirectory(realRoot, fileManager),
              SiteLocator.isExportInside(exportDir: root) else { return .notFound }
        let trailingSlash = decoded.hasSuffix("/")
        let candidate = parts.isEmpty ? realRoot : (realRoot as NSString).appendingPathComponent(parts.joined(separator: "/"))

        if let real = inside(candidate, realRoot: realRoot) {
            if isDirectory(real, fileManager) {
                let index = (real as NSString).appendingPathComponent("index.html")
                let indexFile = inside(index, realRoot: realRoot).flatMap { isRegularFile($0, fileManager) ? $0 : nil }
                if !parts.isEmpty && !trailingSlash {
                    // `trailingSlash: false` の書き出しは `blog.html` と `blog/` が並ぶので、index.html の無いフォルダより先に引く。
                    if indexFile == nil, let file = inside(candidate + ".html", realRoot: realRoot), isRegularFile(file, fileManager) {
                        return .file(file)
                    }
                    return .redirect(location(parts) + "/")
                }
                return indexFile.map(Resolution.file) ?? .notFound
            }
            if trailingSlash { return .notFound }
            if isRegularFile(real, fileManager) { return .file(real) }
            return .notFound
        }
        if fileManager.fileExists(atPath: candidate) || isSymlink(candidate, fileManager) { return .forbidden }
        // `trailingSlash: false` の書き出しは `/about` → `about.html` の形になる。
        if !trailingSlash, let last = parts.last, (last as NSString).pathExtension.isEmpty {
            if let file = inside(candidate + ".html", realRoot: realRoot), isRegularFile(file, fileManager) { return .file(file) }
        }
        return .notFound
    }

    /// 転送先は分けた部分から組み直す（`//host` の形にして別のサイトへ飛ばさせない）。
    static func location(_ parts: [String]) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        return "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    /// 書き出しに 404.html があればそれ。
    public static func notFoundPage(root: String, fileManager: FileManager = .default) -> String? {
        guard let realRoot = SiteLocator.realPath(root), SiteLocator.isExportInside(exportDir: root) else { return nil }
        let page = (realRoot as NSString).appendingPathComponent("404.html")
        guard let file = inside(page, realRoot: realRoot), isRegularFile(file, fileManager) else { return nil }
        return file
    }

    /// 実体が書き出しのフォルダの中にあればその実体のパス。無い・外・隠しファイルを指すなら nil。
    static func inside(_ path: String, realRoot: String) -> String? {
        guard let real = SiteLocator.realPath(path) else { return nil }
        if real == realRoot { return real }
        guard real.hasPrefix(realRoot + "/") else { return nil }
        // 隠しでない名前のリンクから .env 等の実体を返さない。
        let rest = real.dropFirst(realRoot.count + 1).split(separator: "/")
        return rest.contains(where: { $0.hasPrefix(".") }) ? nil : real
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isRegularFile(_ path: String, _ fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    private static func isSymlink(_ path: String, _ fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    // MARK: - Content-Type

    static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "txt": "text/plain; charset=utf-8", "xml": "application/xml; charset=utf-8", "csv": "text/csv; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon", "bmp": "image/bmp",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime", "mp3": "audio/mpeg", "wav": "audio/wav",
        "pdf": "application/pdf", "wasm": "application/wasm",
    ]

    /// 拡張子から Content-Type を決める（知らないものは中身を推測させない汎用の型）。
    public static func contentType(for path: String) -> String {
        contentTypes[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
