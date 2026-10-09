import SwiftUI
import MonitorKit

/// 中央: 「ディレクトリ」で選んだプロジェクトの詳細（見出しの操作と、サイト・画像・iPhone のプレビュー・リンク・スレッドのタブ）。
struct DirectoryDetailView: View {
    let model: ChatModel
    let directory: ProjectDirectory

    var body: some View {
        VStack(spacing: 0) {
            DirectoryDetailHeader(model: model, project: directory.project)
            // 別のプロジェクトへ移ったら、選んだタブ・走査の結果・見る元・表示中のページを持ち越さない。
            DirectoryDetailTabs(model: model, directory: directory).id(directory.project.id)
        }
        .background(ChatTheme.background)
    }
}

/// タブの列と、選んだタブの節だけを欄いっぱいに出す本文。
private struct DirectoryDetailTabs: View {
    let model: ChatModel
    let directory: ProjectDirectory

    @State private var remembered: DirectoryTab?
    @State private var hasSite: Bool?
    @State private var images = ProjectImageStore()
    @State private var iosPreviews = BackgroundScan<SwiftPreviewScan>()
    @State private var visibleHeight: Double?

    init(model: ChatModel, directory: ProjectDirectory) {
        self.model = model
        self.directory = directory
        _remembered = State(initialValue: DirectoryTabMemory().remembered(for: directory.project.id))
    }

    private var project: ManagedProject { directory.project }

    /// 文章の節を抑える幅（サイトのプレビューと画像は欄いっぱい）。
    private static let readableWidth: CGFloat = 900
    private static let padding: CGFloat = 20

    var body: some View {
        let xcodeProject = model.editors.xcodeProject(for: project.editorTarget)
        let rooms = threadRooms
        let available = DirectoryTabs.available(hasSite: hasSite, hasXcodeProject: xcodeProject != nil)
        let selection = DirectoryTabs.resolve(remembered: remembered, available: available)
        VStack(spacing: 0) {
            DirectoryTabBar(items: available.map { DirectoryTabBar.Item(tab: $0, count: count(of: $0, rooms: rooms)) },
                            selection: selection) { tab in
                remembered = tab
                DirectoryTabMemory().remember(tab, for: project.id)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(selection, xcodeProject: xcodeProject, rooms: rooms)
                }
                .padding(Self.padding)
                // 中身が広くてもスクロール欄の幅に収め、はみ出して中央寄せにさせない。
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            // タブを替えたら前のタブのスクロール位置を持ち越さない。
            .id(selection)
            .scrollIndicators(.automatic)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { visibleHeight = $0 }
        }
        // サイトの有無は軽い探索だけで決め、配信や開発サーバーの確かめはサイトのタブを開いた時に回す。
        .task(id: SiteTaskKey(project: project, token: 0)) {
            let project = project
            let lookup = await Task.detached(priority: .userInitiated) { SiteLocator.lookup(project: project) }.value
            guard !Task.isCancelled else { return }
            hasSite = DirectoryTabs.hasSite(lookup)
        }
    }

    @ViewBuilder
    private func section(_ tab: DirectoryTab, xcodeProject: URL?, rooms: [Room]) -> some View {
        switch tab {
        case .site:
            SitePreviewSection(project: project, availableHeight: visibleHeight.map { $0 - Double(Self.padding) * 2 })
        case .images:
            ProjectImagesSection(project: project, store: images)
        case .iosPreviews:
            if let xcodeProject {
                IOSPreviewsSection(project: project, xcodeProject: xcodeProject, list: iosPreviews)
            }
        case .links:
            links.frame(maxWidth: Self.readableWidth, alignment: .leading)
        case .threads:
            threads(rooms).frame(maxWidth: Self.readableWidth, alignment: .leading)
        }
    }

    /// 画像と iPhone は走査し終えた時だけ数を出す。
    private func count(of tab: DirectoryTab, rooms: [Room]) -> Int? {
        switch tab {
        case .site: return nil
        case .images: return images.scan?.count
        case .iosPreviews: return iosPreviews.value?.count
        case .links: return project.links.count
        case .threads: return rooms.count
        }
    }

    private var threadRooms: [Room] {
        let byId = Dictionary(model.rooms.map { ($0.id.string, $0) }, uniquingKeysWith: { a, _ in a })
        return directory.ids.compactMap { byId[$0] }
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

    private func threads(_ rooms: [Room]) -> some View {
        DetailSection(title: "スレッド  \(rooms.count)") {
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
            .xcodeCloseConfirmation(isPresented: $confirmingClose, editors: editors, target: target, project: xcodeProject)
        }
        .centerHeaderBar()
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
            HeaderAction.vscode(priority: 7, editors: editors, target: target),
            .button(id: "finder", priority: 3, symbol: "folder", name: "Finder",
                    detail: "Finder で表示: \(project.path)") { editors.revealInFinder(target) },
        ]
        if let github = HeaderAction.github(priority: 5, editors: editors, target: target) { actions.append(github) }
        actions += HeaderAction.pins(priority: 4, editors: editors, target: target)
        if let links = HeaderAction.links(priority: 4, editors: editors, target: target) { actions.append(links) }
        actions += HeaderAction.xcode(openPriority: 6, closePriority: 2, editors: editors, target: target,
                                      project: xcodeProject) { confirmingClose = true }
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

/// 選んだディレクトリが設定から外された時。
struct DirectoryMissingView: View {
    var body: some View {
        CenterPlaceholder(symbol: "folder.badge.questionmark",
                          text: "このディレクトリは設定から外されました。左の一覧から選び直してください。")
            .background(ChatTheme.background)
    }
}
