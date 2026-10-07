import Foundation

/// アプリが手元に置くファイルの場所（いずれも `claude-deck` の下）。
public enum DeckPaths {
    /// `~/Library/Application Support/claude-deck`。
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-deck", isDirectory: true)
    }

    /// statusline.sh と同じく `HOME` を基準にした Application Support。
    public static func applicationSupport(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/claude-deck", isDirectory: true)
    }

    /// Application Support の `name`。環境変数 `key` があればそちら（`~` を展開する）。
    public static func file(_ name: String, overriddenBy key: String, environment: [String: String]) -> URL {
        if let path = environment[key], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return applicationSupport.appendingPathComponent(name)
    }

    /// 既定の Application Support 直下のファイルか（そこだけディレクトリを 0700 に締め、人が選んだ場所の権限は変えない）。
    public static func isInApplicationSupport(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == applicationSupport.standardizedFileURL.path
    }

    /// `~/Library/Caches/claude-deck`。
    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("claude-deck", isDirectory: true)
    }

    /// `~/Library/Logs/claude-deck`。
    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/claude-deck", isDirectory: true)
    }
}
