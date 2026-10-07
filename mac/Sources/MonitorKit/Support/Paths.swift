import Foundation

enum FilePaths {
    /// シンボリックリンクを解いた実体のパス（無ければ nil）。
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum URLPath {
    /// URL のパスの 1 区間としてエンコードする（区切りや `?` `#` を混ぜない）。空になれば nil。
    static func segment(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        return encoded
    }
}
