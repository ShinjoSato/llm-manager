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
