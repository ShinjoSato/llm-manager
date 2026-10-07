import SwiftUI
import MonitorKit

/// 中央: 「ディレクトリ」で選んだプロジェクトの詳細（概要・操作・サイト・画像・GitHub の紐づけ・リンク・スレッド）。
struct DirectoryDetailView: View {
    let model: ChatModel
    let directory: ProjectDirectory

    @State private var visibleHeight: Double?

    private var project: ManagedProject { directory.project }

    /// 文章の節を抑える幅（サイトのプレビューは欄いっぱい）。
    private static let readableWidth: CGFloat = 900

    var body: some View {
        VStack(spacing: 0) {
            DirectoryDetailHeader(model: model, project: project)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overview.frame(maxWidth: Self.readableWidth, alignment: .leading)
                    // 別のプロジェクトへ移ったら見る元と表示中のページを持ち越さない。
                    SitePreviewSection(project: project, visibleHeight: visibleHeight).id(project.id)
                    // 別のプロジェクトへ移ったら前の一覧とサムネイルを持ち越さない。
                    ProjectImagesSection(project: project).id(project.id)
                    github.frame(maxWidth: Self.readableWidth, alignment: .leading)
                    links.frame(maxWidth: Self.readableWidth, alignment: .leading)
                    threads.frame(maxWidth: Self.readableWidth, alignment: .leading)
                }
                .padding(20)
                // 中身が広くてもスクロール欄の幅に収め、はみ出して中央寄せにさせない。
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { visibleHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in visibleHeight = height }
                }
            }
        }
        .background(ChatTheme.background)
    }

    private var overview: some View {
        DetailSection(title: "概要") {
            DetailField(label: "パス") {
                Text(project.path)
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.text)
                    .textSelection(.enabled)
            }
            DetailField(label: "状態") {
                Text(project.status.label)
                    .font(ChatTheme.body)
                    .foregroundStyle(ChatTheme.text)
            }
            DetailField(label: "メモ") {
                Text(project.note.isEmpty ? "なし" : project.note)
                    .font(ChatTheme.body)
                    .foregroundStyle(project.note.isEmpty ? ChatTheme.tertiary : ChatTheme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var github: some View {
        DetailSection(title: "GitHub") {
            if let link = project.github {
                DetailField(label: "owner") { detailText(link.owner) }
                DetailField(label: "リポジトリ") { detailText(link.repo) }
                DetailField(label: "Project 番号") { detailText(link.projectNumber.map(String.init)) }
            } else {
                emptyText("紐づけなし（設定の GitHub タブで紐づけます）")
            }
        }
    }

    /// 設定の `links` を全部出す（開けないものは理由付きで薄く）。追加・編集・並べ替え・削除はここから設定ファイルに書く。
    private var links: some View {
        let links = project.links
        let problems = SettingsValidation.projectLinkRowProblems(links)
        let target = project.editorTarget
        return DetailSection(title: "リンク") {
            if links.isEmpty { emptyText("なし") }
            if let error = LinkVisitStore.shared.saveError {
                Text(error).font(ChatTheme.caption).foregroundStyle(ChatTheme.error)
            }
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                ProjectLinkRow(projectID: project.id, index: index, count: links.count, link: link,
                               problems: problems.indices.contains(index) ? problems[index] : []) {
                    model.editors.openLink(link, for: target, projectID: project.id)
                }
            }
            ProjectLinkAddButton(projectID: project.id)
        }
    }

    private var threads: some View {
        let byId = Dictionary(model.rooms.map { ($0.id.string, $0) }, uniquingKeysWith: { a, _ in a })
        let rooms = directory.ids.compactMap { byId[$0] }
        return DetailSection(title: "スレッド  \(rooms.count)") {
            if rooms.isEmpty { emptyText("スレッドなし") }
            ForEach(rooms) { room in
                Button { model.select(room.id) } label: {
                    RoomRow(room: room, selected: false)
                        .equatable()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("このルームの会話を開く")
            }
        }
    }

    private func detailText(_ value: String?) -> some View {
        Text(value ?? "なし")
            .font(ChatTheme.mono)
            .foregroundStyle(value == nil ? ChatTheme.tertiary : ChatTheme.text)
            .textSelection(.enabled)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(ChatTheme.caption)
            .foregroundStyle(ChatTheme.tertiary)
    }
}

/// 詳細の見出し（名前・状態・パスと操作ボタン）。高さと下線は会話の見出しにそろえる。
private struct DirectoryDetailHeader: View {
    let model: ChatModel
    let project: ManagedProject
    @State private var confirmingClose = false

    var body: some View {
        let editors = model.editors
        let target = project.editorTarget
        let running = model.runningSession(for: project) != nil
        let xcodeProject = editors.xcodeProject(for: target)
        HStack(spacing: 12) {
            ProjectBadgeView(badge: ProjectBadge.resolve(project: project), size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(ChatTheme.headline)
                        .foregroundStyle(ChatTheme.heading)
                        .lineLimit(1)
                    ProjectStatusTag(status: project.status)
                }
                Text(project.path)
                    .truncationMode(.middle)
                    .font(ChatTheme.mono)
                    .foregroundStyle(ChatTheme.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: HeaderLayout.titleMinWidth, alignment: .leading)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                EditorNoteText(note: editors.notes[target.key])
                HeaderActionRow(actions: actions(editors: editors, target: target, running: running, xcodeProject: xcodeProject))
                    .layoutPriority(1)
            }
            // 名前を最小幅まで縮めてからボタンを「…」に回す。
            .layoutPriority(1)
            // メニューから押しても確認を出せるよう、ボタンではなく列に付ける。
            .confirmationDialog("Xcode から閉じますか？", isPresented: $confirmingClose) {
                Button("閉じる", role: .destructive) { editors.closeInXcode(target) }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("\(xcodeProject?.lastPathComponent ?? "ワークスペース") を Xcode から閉じます。Xcode は終了せず、起動していなければ何もしません。未保存の変更があれば Xcode が確認を出します。")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .headerBackground()
        .zIndex(1)
    }

    /// priority の小さいものから「…」に隠れる（設定で編集 → 閉じる → Finder → ピン → リンク → GitHub → Xcode → VS Code → 起動）。
    private func actions(editors: EditorLauncher, target: EditorTarget, running: Bool, xcodeProject: URL?) -> [HeaderAction] {
        let project = project
        var actions: [HeaderAction] = [
            .button(id: "launch", priority: 8, symbol: running ? "arrow.right.circle" : "play.fill",
                    name: running ? "ルームへ移る" : "Claude Code を起動",
                    detail: running ? "このプロジェクトで動いているルームを開く" : "このプロジェクトで claude を起動して新しいルームを開く") {
                model.launch(project)
            },
            .button(id: "vscode", priority: 7, symbol: VSCodeButton.symbol, name: VSCodeButton.name,
                    detail: VSCodeButton.detail(target)) { editors.openInVSCode(target) },
            .button(id: "finder", priority: 3, symbol: "folder", name: "Finder",
                    detail: "Finder で表示: \(project.path)") { editors.revealInFinder(target) },
        ]
        if let github = HeaderAction.github(priority: 5, editors: editors, target: target) { actions.append(github) }
        actions += HeaderAction.pins(priority: 4, editors: editors, target: target)
        if let links = HeaderAction.links(priority: 4, editors: editors, target: target) { actions.append(links) }
        if let xcodeProject {
            let closing = editors.closingXcode.contains(target.key)
            actions.append(.button(id: "xcode", priority: 6, symbol: "hammer", name: "Xcode",
                                   detail: "Xcode で開く: \(xcodeProject.path)") { editors.openInXcode(target) })
            actions.append(.button(id: "xcode-close", priority: 2, symbol: "xmark.rectangle", name: "閉じる",
                                   detail: "Xcode からこのワークスペースだけを閉じる（Xcode は終了しません）",
                                   busyStatus: closing ? "閉じています…" : nil) { confirmingClose = true })
        }
        actions.append(.button(id: "settings", priority: 1, symbol: "gearshape", name: "設定で編集",
                               detail: "設定画面のプロジェクトタブで開く") {
            SettingsWindow.show(tab: .projects, project: project.id)
        })
        return actions
    }
}

/// 設定の状態（進行中・休止・保管）。
private struct ProjectStatusTag: View {
    let status: ProjectStatus

    var body: some View {
        let color = status == .active ? ChatTheme.working : ChatTheme.tertiary
        Text(status.label)
            .statusCapsule(color)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .sectionLabelStyle()
            content
        }
        .detailCard()
    }
}

private struct DetailField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .frame(width: 88, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// 選んだディレクトリが設定から外された時。
struct DirectoryMissingView: View {
    var body: some View {
        CenterPlaceholder(symbol: "folder.badge.questionmark",
                          text: "このディレクトリは設定から外されました。左の一覧から選び直してください。")
            .background(ChatTheme.background)
    }
}
