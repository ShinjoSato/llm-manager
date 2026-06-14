import AppKit

// claude-deck — プロジェクトごとに Claude Code を同時起動する macOS 司令塔アプリ（PoC）。
// SPM 実行ファイルから NSApplication を直接立ち上げる（.app バンドル化は後工程）。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
