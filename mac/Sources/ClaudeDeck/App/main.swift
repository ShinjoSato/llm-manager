import AppKit
import MonitorKit

// claude-deck — プロジェクトごとに Claude Code を同時起動する macOS 司令塔アプリ（PoC）。

// 設定ファイルの場所を GUI を出さずに確かめるため（jq で読む時の手がかり）。
if CommandLine.arguments.contains("--print-settings-path") {
    print(SettingsFile.defaultURL().path)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
