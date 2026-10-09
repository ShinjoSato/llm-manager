import SwiftUI
import MonitorKit

enum HeaderLayout {
    /// 見出しの名前とパスが省略表示でも読める幅。
    static let titleMinWidth: CGFloat = 140
}

extension View {
    /// 中央の見出しの帯（会話とディレクトリの詳細で高さと下線をそろえる）。
    func centerHeaderBar() -> some View {
        padding(.horizontal, 20)
            .frame(height: 64)
            .headerBackground()
    }

    /// Xcode のワークスペースを閉じる前の確認。メニューから押しても出せるよう、ボタンではなく列に付ける。
    func xcodeCloseConfirmation(isPresented: Binding<Bool>, editors: EditorLauncher, target: EditorTarget,
                                project: URL?) -> some View {
        confirmationDialog("Xcode から閉じますか？", isPresented: isPresented) {
            Button("閉じる", role: .destructive) { editors.closeInXcode(target) }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("\(project?.lastPathComponent ?? "ワークスペース") を Xcode から閉じます。Xcode は終了せず、起動していなければ何もしません。未保存の変更があれば Xcode が確認を出します。")
        }
    }
}

/// 見出しのボタン 1 つ分。入りきらない時は「…」のメニューに `menuItem` として並ぶ（同じ動作を呼ぶ）。
@MainActor
struct HeaderAction: Identifiable {
    let id: String
    let name: String
    /// 大きいほど最後まで見出しに残る。
    let priority: Int
    /// 同じ priority の中での順（小さいものから先に隠れる。ピンは「リンク」の直前に隠れるよう負にする）。
    var subpriority: Int = 0
    let button: AnyView
    let menuItem: AnyView

    /// 押すと 1 つの動作をするボタン。
    static func button(id: String, priority: Int, symbol: String, name: String, detail: String? = nil,
                       busyStatus: String? = nil, action: @escaping () -> Void) -> HeaderAction {
        HeaderAction(id: id, name: name, priority: priority,
                     button: AnyView(HeaderButton(symbol: symbol, name: name, detail: detail, busyStatus: busyStatus, action: action)),
                     menuItem: AnyView(HeaderMenuItem(symbol: symbol, name: name, busyStatus: busyStatus, action: action)))
    }

    /// 「VS Code」。
    static func vscode(priority: Int, editors: EditorLauncher, target: EditorTarget) -> HeaderAction {
        .button(id: "vscode", priority: priority, symbol: "chevron.left.forwardslash.chevron.right", name: "VS Code",
                detail: "VS Code で開く: \(target.cwd)") { editors.openInVSCode(target) }
    }

    /// 「別ウィンドウで開く」。
    static func openInWindow(priority: Int, subpriority: Int, action: @escaping () -> Void) -> HeaderAction {
        var item = HeaderAction.button(id: "window", priority: priority, symbol: "macwindow.badge.plus", name: "別ウィンドウで開く",
                                       detail: "このルームを別のウィンドウで開く（開いていれば前に出す）", action: action)
        item.subpriority = subpriority
        return item
    }

    /// 「Xcode」と「閉じる」（`project` が無ければ出さない）。閉じるは `onClose` で確認を開く。
    static func xcode(openPriority: Int, closePriority: Int, editors: EditorLauncher, target: EditorTarget,
                      project: URL?, onClose: @escaping () -> Void) -> [HeaderAction] {
        guard let project else { return [] }
        let closing = editors.closingXcode.contains(target.key)
        return [
            .button(id: "xcode", priority: openPriority, symbol: "hammer", name: "Xcode",
                    detail: "Xcode で開く: \(project.path)") { editors.openInXcode(target) },
            .button(id: "xcode-close", priority: closePriority, symbol: "xmark.rectangle", name: "閉じる",
                    detail: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                    busyStatus: closing ? "閉じています…" : nil, action: onClose),
        ]
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

    /// ピン留めしたリンク（種類のアイコンの単独ボタン。設定の順に最大 3 つ）。「リンク」と同じ priority で、その直前に隠れる。
    static func pins(priority: Int, editors: EditorLauncher, target: EditorTarget) -> [HeaderAction] {
        let projectID = editors.projectID(for: target)
        return editors.pinnedLinks(for: target).map { link in
            let due = projectID.map { LinkVisitStore.shared.isDue(projectID: $0, link: link) } ?? false
            let reminder = link.validReminderDay.map { "確認が必要です（\(LinkReminder.label(day: $0))）" }
            let detail = [ProjectLinks.help(for: link), due ? reminder : nil].compactMap { $0 }.joined(separator: "\n")
            return HeaderAction(id: "pin:\(link.name)", name: link.name, priority: priority, subpriority: -1,
                                button: AnyView(HeaderButton(symbol: link.resolvedKind.symbol, name: link.name, detail: detail, dot: due) {
                                    editors.openLink(link, for: target)
                                }),
                                menuItem: AnyView(HeaderMenuItem(symbol: link.resolvedKind.symbol,
                                                                 name: due ? "\(link.name)（確認が必要）" : link.name, busyStatus: nil) {
                                    editors.openLink(link, for: target)
                                }))
        }
    }

    /// 「リンク」。開けるリンクが無ければ出さない。
    static func links(priority: Int, editors: EditorLauncher, target: EditorTarget) -> HeaderAction? {
        let links = editors.projectLinks(for: target)
        guard !links.isEmpty else { return nil }
        let menu: AnyView
        if links.count == 1, let only = links.first {
            menu = AnyView(HeaderMenuItem(symbol: only.resolvedKind.symbol, name: "\(ProjectLinkButton.name): \(only.name)",
                                          busyStatus: nil) { editors.openLink(only, for: target) })
        } else {
            menu = AnyView(Menu {
                ProjectLinkMenuItems(links: links) { editors.openLink($0, for: target) }
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
        let subpriorities = actions.map(\.subpriority)
        let visible = HeaderOverflow.visibleIndices(priorities: priorities, subpriorities: subpriorities, hiddenCount: hiddenCount)
        let hidden = HeaderOverflow.hiddenIndices(priorities: priorities, subpriorities: subpriorities, hiddenCount: hiddenCount)
        return HStack(spacing: 6) {
            ForEach(visible, id: \.self) { index in actions[index].button }
            if !hidden.isEmpty {
                let overflow = hidden.map { actions[$0] }
                // 入りきらなかったボタンをまとめた「…」。
                HeaderMenuButton(symbol: "ellipsis.circle", name: "ほかの操作", detail: overflow.map(\.name).joined(separator: "\n"),
                                 showsChevron: false) {
                    ForEach(overflow) { $0.menuItem }
                }
            }
        }
        .fixedSize()
    }
}
