import Foundation

/// 作業場所から Xcode で開く対象を探す（`ios/` 等の下にあることが多いので浅く潜る）。
public enum XcodeFinder {
    static let maxDepth = 3
    /// 走査するディレクトリ数の上限。cwd が巨大でも監視が止まらないようにする。
    static let maxDirs = 2_000
    /// 潜っても無駄か、誤検出のもとになるディレクトリ。
    static let skip: Set<String> = [".git", "Pods", "node_modules", ".build", "DerivedData", "build", ".swiftpm"]

    private struct Candidate {
        var path: String
        var depth: Int
        var workspace: Bool
    }

    /// `.xcworkspace` 優先・最も浅い階層のものを 1 つ返す。無ければ nil。
    public static func find(in dir: String) -> String? {
        var queue: [(String, Int)] = [(dir, 0)]
        var best: Candidate?
        var i = 0
        while i < queue.count && i < maxDirs {
            // 深さ 0 の候補は最初の 1 周で出揃い、それより浅いものは無いので打ち切れる。
            if best?.depth == 0 { break }
            let (current, depth) = queue[i]
            i += 1
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in entries {
                let path = current.hasSuffix("/") ? current + name : current + "/" + name
                let workspace = name.hasSuffix(".xcworkspace")
                // バンドルには潜らない。`.xcodeproj/project.xcworkspace` は内部ファイルで開く対象ではない。
                if workspace || name.hasSuffix(".xcodeproj") {
                    if better(best, depth: depth, workspace: workspace) { best = Candidate(path: path, depth: depth, workspace: workspace) }
                    continue
                }
                // リンクは辿らない（循環で走査が終わらなくなるため）。
                guard !name.hasPrefix("."), !skip.contains(name), isDirectoryNoFollow(path) else { continue }
                if depth < maxDepth { queue.append((path, depth + 1)) }
            }
        }
        // Xcode が返すのは実パスなので、symlink 配下だと未解決のままでは比較が外れる。
        return best.map { realPath($0.path) }
    }

    private static func isDirectoryNoFollow(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func better(_ best: Candidate?, depth: Int, workspace: Bool) -> Bool {
        guard let best else { return true }
        if depth != best.depth { return depth < best.depth }
        return workspace && !best.workspace
    }
}
