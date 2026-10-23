import DeckCore
import SwiftUI

/// プロジェクトの詳細: 見出し（名前・状態・GitHub）と「リンク」「スレッド」のタブ。スレッドを押すと会話を開く。
struct ProjectDetailScreen: View {
    @Bindable var model: AppModel
    let projectId: String
    /// 2 列で一覧の側に接続の帯が見えている間は重ねて出さない。
    var showsBanner = true

    var body: some View {
        Group {
            if let project = model.project(projectId) {
                content(project)
            } else {
                missing
            }
        }
        .background(DeckTheme.background.ignoresSafeArea())
        .toolbarBackground(DeckTheme.background, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.pullToRefreshProjects() }
        .onAppear { if model.projects == nil { model.refreshProjects() } }
    }

    /// 引っ張って更新できるよう、案内も ScrollView に載せる。
    private var missing: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 28)).foregroundStyle(DeckTheme.tertiary)
                    Text(missingText)
                        .font(DeckTheme.body)
                        .foregroundStyle(DeckTheme.secondary)
                        .multilineTextAlignment(.center)
                    Text("下に引っ張ると読み直します。").font(DeckTheme.caption).foregroundStyle(DeckTheme.tertiary)
                }
                .padding(24)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private var missingText: String {
        switch model.projectsStatus {
        case .outdatedMac: return AppModel.outdatedMacText
        case .failed(let reason): return "一覧を読み込めませんでした（\(reason)）"
        case .loaded: return "このプロジェクトはもう登録されていません。"
        case .idle, .loading: return model.connection.isConnected ? "一覧を読み込んでいます…" : "Mac につながると出ます。"
        }
    }

    private func content(_ project: RemoteProject) -> some View {
        let tab = Binding(get: { model.projectTab(project.id) }, set: { model.projectTabs[project.id] = $0 })
        let rooms = model.rooms(of: project)
        return VStack(spacing: 0) {
            if showsBanner { ConnectionBanner(model: model) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(project)
                    Picker("表示", selection: tab) {
                        ForEach(ProjectDetailTab.allCases) { item in
                            Text(title(item, project: project, rooms: rooms)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("project-tab")
                    switch tab.wrappedValue {
                    case .links: links(project)
                    case .threads: threads(rooms)
                    }
                }
                .padding(16)
                .frame(maxWidth: DeckTheme.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(project.name).font(.system(size: 15, weight: .bold)).foregroundStyle(DeckTheme.heading).lineLimit(1)
            }
        }
    }

    private func title(_ tab: ProjectDetailTab, project: RemoteProject, rooms: [RemoteRoom]) -> String {
        switch tab {
        case .links: return "\(tab.title)  \(project.links.count)"
        case .threads: return "\(tab.title)  \(rooms.count)"
        }
    }

    private func header(_ project: RemoteProject) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ProjectIcon(active: project.isActive)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name).font(DeckTheme.headline).foregroundStyle(DeckTheme.heading).lineLimit(1)
                    Text(project.status.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(project.isActive ? DeckTheme.accent : DeckTheme.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(project.isActive ? DeckTheme.accent : DeckTheme.border))
                }
                if let github = project.github {
                    Label(github.label, systemImage: "chevron.left.forwardslash.chevron.right")
                        .labelStyle(SmallLabelStyle())
                        .font(DeckTheme.mono)
                        .foregroundStyle(DeckTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func links(_ project: RemoteProject) -> some View {
        if project.links.isEmpty {
            empty("リンクがありません", "Mac の claude-deck のディレクトリの詳細か、設定画面の「リンク」で登録すると、ここに出ます。")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(project.links.enumerated()), id: \.offset) { _, link in
                    LinkRow(link: link)
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.sidebar))
        }
    }

    @ViewBuilder
    private func threads(_ rooms: [RemoteRoom]) -> some View {
        if rooms.isEmpty {
            empty("スレッドなし", "Mac の claude-deck でこのプロジェクトの Claude Code を起動すると、ここに出ます。")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rooms) { room in
                    NavigationLink(value: DeckRoute.room(room.id)) {
                        RoomRow(room: room, unread: room.sessionId.flatMap { model.unread[$0] } ?? 0).contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("thread-\(room.name)")
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.sidebar))
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DeckTheme.body).foregroundStyle(DeckTheme.secondary)
            Text(detail).font(DeckTheme.caption).foregroundStyle(DeckTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}
