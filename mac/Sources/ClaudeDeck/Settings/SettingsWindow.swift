import AppKit
import MonitorKit
import Observation
import SwiftUI

enum SettingsTab: Hashable {
    case projects, github, remote, transfer
}

/// 開いている設定画面のタブ（メニューから別のタブを指して開き直せるよう、ビューの外に持つ）。
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .projects
}

/// 設定画面（⌘,）。1 つだけ持つ。
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let navigation = SettingsNavigation()

    /// `tab` が nil なら前に開いていたタブのまま。
    static func show(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        SettingsStore.shared.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(store: .shared, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "設定"
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClaudeDeckSettingsWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct SettingsView: View {
    let store: SettingsStore
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                SettingsProblemBanner(problem: problem, path: store.file.url.path) { store.reload() }
            }
            TabView(selection: $navigation.tab) {
                ProjectSettingsTab(store: store)
                    .tabItem { Label("プロジェクト", systemImage: "folder") }
                    .tag(SettingsTab.projects)
                GitHubSettingsTab(store: store)
                    .tabItem { Label("GitHub", systemImage: "point.3.connected.trianglepath.dotted") }
                    .tag(SettingsTab.github)
                RemoteAccessView(controller: .shared)
                    .tabItem { Label("iPhone 連携", systemImage: "iphone") }
                    .tag(SettingsTab.remote)
                TransferSettingsTab(store: store)
                    .tabItem { Label("書き出し・読み込み", systemImage: "arrow.up.arrow.down") }
                    .tag(SettingsTab.transfer)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

/// 設定ファイルを読めない時の帯。元のファイルは残し、直してもらってから読み直す。
private struct SettingsProblemBanner: View {
    let problem: String
    let path: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("元のファイルは書き換えずに残しています。直してから「読み直す」を押してください。それまでプロジェクトと GitHub の設定は変えられません。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("読み直す", action: retry)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}
