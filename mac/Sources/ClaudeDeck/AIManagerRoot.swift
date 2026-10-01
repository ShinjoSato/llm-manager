import Foundation

/// ai-manager リポジトリのルート（`projects/registry.tsv` を持つディレクトリ）を解決する。
/// 解決順: 環境変数 `AI_MANAGER_ROOT` → UserDefaults `aiManagerRoot` → 実行ファイル位置 / CWD から親へ遡る → 既定の絶対パス。
enum AIManagerRoot {
    static let environmentKey = "AI_MANAGER_ROOT"
    static let defaultsKey = "aiManagerRoot"
    static let fallbackPath = "/Users/shinjo/project/ai-manager"
    /// ルートと判定する目印。
    static let marker = "projects/registry.tsv"

    /// 解決したルート。見つからなければ nil。
    static var url: URL? { resolve() }

    /// ルート配下の相対パスを返す。`envOverride` の環境変数があればそのファイルを最優先する。
    static func file(_ relativePath: String, envOverride: String? = nil) -> URL? {
        let fm = FileManager.default
        if let key = envOverride,
           let env = ProcessInfo.processInfo.environment[key],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        guard let root = url else { return nil }
        let candidate = root.appendingPathComponent(relativePath)
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        executableURL: URL? = Bundle.main.executableURL,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let env = environment[environmentKey], let root = validRoot(env) { return root }
        if let saved = defaults.string(forKey: defaultsKey), let root = validRoot(saved) { return root }

        // .app は cwd が "/" になるため、実行ファイル位置（mac/dist/claude-deck.app/Contents/MacOS）からも遡る。
        var starts: [URL] = []
        if let exe = executableURL { starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        starts.append(URL(fileURLWithPath: currentDirectory))
        for start in starts {
            var dir = start.standardizedFileURL
            for _ in 0..<8 {
                if let root = validRoot(dir.path) { return root }
                if dir.path == "/" { break }
                dir.deleteLastPathComponent()
            }
        }
        return validRoot(fallbackPath)
    }

    private static func validRoot(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded, isDirectory: true)
        let markerPath = root.appendingPathComponent(marker).path
        return FileManager.default.fileExists(atPath: markerPath) ? root : nil
    }
}
