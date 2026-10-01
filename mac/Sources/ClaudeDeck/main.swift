import AppKit

// claude-deck — プロジェクトごとに Claude Code を同時起動する macOS 司令塔アプリ（PoC）。

// .app から起動したときにルート解決が効いているかを GUI を出さずに確かめるため。
if CommandLine.arguments.contains("--print-ai-manager-root") {
    print(AIManagerRoot.url?.path ?? "(unresolved)")
    print(ProjectRegistry.registryURL()?.path ?? "(registry.tsv unresolved)")
    exit(AIManagerRoot.url == nil ? 1 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
