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

    private var links: some View {
        let openable = ProjectLinks.openable(project.links)
        let target = project.editorTarget
        return DetailSection(title: "リンク") {
            if openable.isEmpty { emptyText("なし") }
            ForEach(Array(openable.enumerated()), id: \.offset) { _, link in
                Button { model.editors.openLink(link, for: target) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(ChatTheme.link)
                        Text(link.name).font(ChatTheme.body).foregroundStyle(ChatTheme.text).lineLimit(1)
                        Text(link.url).font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ProjectLinks.help(for: link))
            }
            if project.links.count > openable.count {
                emptyText("開けない形・名前が重なるリンク \(project.links.count - openable.count) 件は出していません")
            }
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

    var body: some View {
        let editors = model.editors
        let target = project.editorTarget
        let running = model.runningSession(for: project) != nil
        HStack(spacing: 12) {
            RoomAvatar(name: project.name, size: 38)
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
                HeaderActionRow(actions: actions(editors: editors, target: target, running: running)).layoutPriority(1)
            }
            // 名前を最小幅まで縮めてからボタンを「…」に回す。
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        // 下線は背景側に置き、ボタンの吹き出しが線の下に潜らないようにする。
        .background {
            ChatTheme.background.overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
        }
        .zIndex(1)
    }

    private func actions(editors: EditorLauncher, target: EditorTarget, running: Bool) -> [HeaderAction] {
        let project = project
        var actions: [HeaderAction] = [
            .button(id: "launch", priority: 6, symbol: running ? "arrow.right.circle" : "play.fill",
                    name: running ? "ルームへ移る" : "Claude Code を起動",
                    detail: running ? "このプロジェクトで動いているルームを開く" : "このプロジェクトで claude を起動して新しいルームを開く") {
                model.launch(project)
            },
            .button(id: "vscode", priority: 5, symbol: VSCodeButton.symbol, name: VSCodeButton.name,
                    detail: VSCodeButton.detail(target)) { editors.openInVSCode(target) },
            .button(id: "finder", priority: 2, symbol: "folder", name: "Finder",
                    detail: "Finder で表示: \(project.path)") { editors.revealInFinder(target) },
        ]
        if let github = HeaderAction.github(priority: 4, editors: editors, target: target) { actions.append(github) }
        if let links = HeaderAction.links(priority: 3, editors: editors, target: target) { actions.append(links) }
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatTheme.tertiary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.claudeBubble))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.claudeBubbleBorder))
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
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(ChatTheme.tertiary)
            Text("このディレクトリは設定から外されました。左の一覧から選び直してください。")
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.background)
    }
}
