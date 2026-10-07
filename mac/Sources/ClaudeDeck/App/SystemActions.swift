import AppKit

/// Finder・クリップボード・ファイルを選ぶパネルの決まった呼び方。
@MainActor
enum SystemActions {
    /// Finder でその場所を選んで見せる。
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func revealInFinder(path: String) {
        revealInFinder(URL(fileURLWithPath: path))
    }

    /// 文字列をクリップボードに置く。
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ファイルかフォルダを選ばせる。取り消せば空。
    static func choose(folders: Bool, multiple: Bool, prompt: String, message: String? = nil, directory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        if let message { panel.message = message }
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
