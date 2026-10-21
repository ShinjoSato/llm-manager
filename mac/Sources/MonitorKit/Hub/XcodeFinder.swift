import Foundation

/// 作業場所から Xcode で開く対象を探す（`ios/` 等の下にあることが多いので浅く潜る）。
public enum XcodeFinder {
    static let maxDepth = 3
    /// 走査するディレクトリ数の上限。cwd が巨大でも監視が止まらないようにする。
    static let maxDirs = 2_000
    /// 潜っても無駄か、誤検出のもとになるディレクトリ。
    static let skip: Set<String> = [".git", "Pods", "node_modules", ".build", "DerivedData", "build", ".swiftpm"]
    /// 設定画面に出す候補の上限。
    public static let maxCandidates = 50

    private struct Candidate {
        var path: String
        var depth: Int
        var workspace: Bool
    }

    /// `.xcworkspace` 優先・最も浅い階層のものを 1 つ返す。無ければ nil。
    public static func find(in dir: String) -> String? {
        var best: Candidate?
        walk(dir) { candidate in
            if better(best, than: candidate) { best = candidate }
            // 深さ 0 の候補は最初の 1 周で出揃い、それより浅いものは無いので打ち切れる。
            return best?.depth != 0
        }
        // Xcode が返すのは実パスなので、symlink 配下だと未解決のままでは比較が外れる。
        return best.map { FilePaths.realPath($0.path) ?? $0.path }
    }

    /// `find` と同じ範囲の候補を、`dir` からの相対パスで浅い順（同じ深さは `.xcworkspace` が先・名前順）に返す。
    public static func candidates(in dir: String, limit: Int = maxCandidates) -> [String] {
        var found: [Candidate] = []
        walk(dir) { found.append($0); return true }
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        return found
            .sorted { a, b in
                if a.depth != b.depth { return a.depth < b.depth }
                if a.workspace != b.workspace { return a.workspace }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.path.hasPrefix(base) ? String($0.path.dropFirst(base.count)) : $0.path }
    }

    /// 見つけるたびに `visit` を呼ぶ。`visit` が false を返したら、その深さの周回を終えた所で打ち切る。
    private static func walk(_ dir: String, visit: (Candidate) -> Bool) {
        var queue: [(String, Int)] = [(dir, 0)]
        var i = 0
        var keepGoing = true
        while i < queue.count && i < maxDirs {
            let (current, depth) = queue[i]
            if !keepGoing && depth > 0 { break }
            i += 1
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in entries.sorted() {
                let path = current.hasSuffix("/") ? current + name : current + "/" + name
                let workspace = name.hasSuffix(".xcworkspace")
                // バンドルには潜らない。`.xcodeproj/project.xcworkspace` は内部ファイルで開く対象ではない。
                if workspace || name.hasSuffix(".xcodeproj") {
                    if !visit(Candidate(path: path, depth: depth, workspace: workspace)) { keepGoing = false }
                    continue
                }
                // リンクは辿らない（循環で走査が終わらなくなるため）。
                guard !name.hasPrefix("."), !skip.contains(name), isDirectoryNoFollow(path) else { continue }
                if depth < maxDepth { queue.append((path, depth + 1)) }
            }
        }
    }

    private static func isDirectoryNoFollow(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func better(_ best: Candidate?, than candidate: Candidate) -> Bool {
        guard let best else { return true }
        if candidate.depth != best.depth { return candidate.depth < best.depth }
        return candidate.workspace && !best.workspace
    }
}
