import SwiftUI
import MonitorKit

enum HeaderLayout {
    /// 見出しの名前とパスが省略表示でも読める幅。
    static let titleMinWidth: CGFloat = 140
}

/// 見出しのボタン 1 つ分。入りきらない時は「…」のメニューに `menuItem` として並ぶ（同じ動作を呼ぶ）。
@MainActor
struct HeaderAction: Identifiable {
    let id: String
    let name: String
    /// 大きいほど最後まで見出しに残る。
    let priority: Int
    let button: AnyView
    let menuItem: AnyView

    /// 押すと 1 つの動作をするボタン。
    static func button(id: String, priority: Int, symbol: String, name: String, detail: String? = nil,
                       busyStatus: String? = nil, action: @escaping () -> Void) -> HeaderAction {
        HeaderAction(id: id, name: name, priority: priority,
                     button: AnyView(HeaderButton(symbol: symbol, name: name, detail: detail, busyStatus: busyStatus, action: action)),
                     menuItem: AnyView(HeaderMenuItem(symbol: symbol, name: name, busyStatus: busyStatus, action: action)))
    }

    /// 「GitHub」。開く先が無ければ出さない。
    static func github(priority: Int, editors: EditorLauncher, target: EditorTarget) -> HeaderAction? {
        let destinations = editors.githubDestinations(for: target)
        guard !destinations.isEmpty else { return nil }
        let opening = editors.openingGitHub.contains(target.key)
        let menu: AnyView
        if destinations.count == 1, let only = destinations.first {
            menu = AnyView(HeaderMenuItem(symbol: GitHubButton.symbol, name: GitHubButton.name,
                                          busyStatus: opening ? "開いています…" : nil) { editors.openOnGitHub(only, for: target) })
        } else {
            menu = AnyView(Menu {
                ForEach(Array(destinations.enumerated()), id: \.offset) { _, destination in
                    Button(destination.menuTitle) { editors.openOnGitHub(destination, for: target) }
                }
            } label: {
                Label(opening ? "\(GitHubButton.name)（開いています…）" : GitHubButton.name, systemImage: GitHubButton.symbol)
            }
            .disabled(opening))
        }
        return HeaderAction(id: "github", name: GitHubButton.name, priority: priority,
                            button: AnyView(GitHubButton(editors: editors, target: target, destinations: destinations, opening: opening)),
                            menuItem: menu)
    }

    /// 「リンク」。開けるリンクが無ければ出さない。
    static func links(priority: Int, editors: EditorLauncher, target: EditorTarget) -> HeaderAction? {
        let links = editors.projectLinks(for: target)
        guard !links.isEmpty else { return nil }
        let menu: AnyView
        if links.count == 1, let only = links.first {
            menu = AnyView(HeaderMenuItem(symbol: ProjectLinkButton.symbol, name: "\(ProjectLinkButton.name): \(only.name)",
                                          busyStatus: nil) { editors.openLink(only, for: target) })
        } else {
            menu = AnyView(Menu {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button(link.name) { editors.openLink(link, for: target) }
                }
            } label: {
                Label(ProjectLinkButton.name, systemImage: ProjectLinkButton.symbol)
            })
        }
        return HeaderAction(id: "links", name: ProjectLinkButton.name, priority: priority,
                            button: AnyView(ProjectLinkButton(editors: editors, target: target, links: links)),
                            menuItem: menu)
    }
}

/// メニューに回った時の項目。処理中は状態を添えて押せなくする。
private struct HeaderMenuItem: View {
    let symbol: String
    let name: String
    let busyStatus: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(busyStatus.map { "\(name)（\($0)）" } ?? name, systemImage: symbol)
        }
        .disabled(busyStatus != nil)
    }
}

/// 見出しのボタン列。幅が足りなければ優先度の低いものから「…」のメニューへ回す。
struct HeaderActionRow: View {
    let actions: [HeaderAction]

    var body: some View {
        // 入るものを先に並べ、最後の候補（全部をメニューに回す）は幅が足りなくても使われる。
        ViewThatFits(in: .horizontal) {
            ForEach(0...actions.count, id: \.self) { hidden in
                row(hiddenCount: hidden)
            }
        }
    }

    private func row(hiddenCount: Int) -> some View {
        let priorities = actions.map(\.priority)
        let visible = HeaderOverflow.visibleIndices(priorities: priorities, hiddenCount: hiddenCount)
        let hidden = HeaderOverflow.hiddenIndices(priorities: priorities, hiddenCount: hiddenCount)
        return HStack(spacing: 6) {
            ForEach(visible, id: \.self) { index in actions[index].button }
            if !hidden.isEmpty {
                HeaderOverflowMenu(actions: hidden.map { actions[$0] })
            }
        }
        .fixedSize()
    }
}

/// 入りきらなかったボタンをまとめた「…」。
private struct HeaderOverflowMenu: View {
    let actions: [HeaderAction]
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(actions) { $0.menuItem }
        } label: {
            HeaderButtonLabel(symbol: "ellipsis.circle", busy: false, disabled: false, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .headerButtonHelp(name: "ほかの操作", detail: actions.map(\.name).joined(separator: "\n"), busyStatus: nil)
        .onHover { hovering = $0 }
    }
}
