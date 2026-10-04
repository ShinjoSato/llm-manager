import Foundation

/// セッションの作業場所から Xcode で開く対象を探す（移植元: 旧 monitor（削除済み）の src/xcode.ts）。
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

/// macOS の `open -a` でエディタに開かせる（移植元: 旧 monitor（削除済み）の src/open.ts）。同じパスを開き直すと既存ウィンドウが前面に出る。
public enum EditorOpen {
    public static let timeout: TimeInterval = 15

    /// `open -a` に渡すアプリ名。受け取った文字列をそのままコマンドへ渡さないための対応表。
    public static func appName(_ app: OpenApp) -> String {
        switch app {
        case .vscode: return "Visual Studio Code"
        case .xcode: return "Xcode"
        }
    }

    /// 実行に失敗した理由。打ち切りは message にコマンド全文が入りうるので出さない。
    public static func failureReason(timedOut: Bool, stderr: String, fallback: String) -> String {
        if timedOut { return "応答がありません（確認ダイアログが出ているかもしれません）" }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// シェルを経由せず引数配列で渡す。成功なら nil、失敗なら理由。
    public static func open(_ app: OpenApp, target: String) async -> String? {
        // 先頭が `-` のパスは open のオプションとして解釈される。
        guard target.hasPrefix("/") else { return "開く先が絶対パスではありません" }
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                             arguments: ["-a", appName(app), target], timeout: timeout)
        if let launchError = result.launchError { return launchError }
        if result.status == 0 && !result.timedOut { return nil }
        return failureReason(timedOut: result.timedOut, stderr: result.stderr, fallback: "終了コード \(result.status)")
    }
}
