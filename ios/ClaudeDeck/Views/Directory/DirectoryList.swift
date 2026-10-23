import DeckCore
import SwiftUI

/// 左の一覧の「ディレクトリ」: 登録したプロジェクト（進行中 → 休止・保管）。押すと詳細（リンク・スレッド）を開く。
struct DirectoryList: View {
    @Bindable var model: AppModel
    @Binding var route: [DeckRoute]
    let regular: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ProjectsStatusView(model: model, emptyTitle: "登録したプロジェクトがありません",
                                   emptyDetail: "Mac の claude-deck の設定（⌘,）の「プロジェクト」で登録すると、ここに出ます。",
                                   isEmpty: { $0.projects.isEmpty })
                if let projects = model.projects {
                    ForEach(projects.active) { row($0) }
                    if !projects.inactive.isEmpty {
                        Text("休止・保管  \(projects.inactive.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DeckTheme.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(projects.inactive) { row($0) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    private func row(_ project: RemoteProject) -> some View {
        SidebarRowLink(step: .project(project.id), route: $route, regular: regular) {
            ProjectRow(project: project, rooms: model.rooms(of: project)).contentShape(Rectangle())
        }
        .accessibilityIdentifier("project-\(project.name)")
    }
}

/// プロジェクト 1 行（名前・状態・GitHub・動いているルームの数・リンクの数）。
struct ProjectRow: View {
    let project: RemoteProject
    let rooms: [RemoteRoom]

    var body: some View {
        let live = ProjectRooms.liveCount(rooms)
        let urgent = ProjectRooms.urgentStatus(rooms)
        HStack(alignment: .top, spacing: 10) {
            ProjectIcon(active: project.isActive)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(project.isActive ? DeckTheme.text : DeckTheme.secondary)
                        .lineLimit(1)
                    if !project.isActive {
                        Text(project.status.label).font(.system(size: 11)).foregroundStyle(DeckTheme.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let urgent {
                        Circle().fill(DeckTheme.color(for: urgent)).frame(width: 7, height: 7)
                            .accessibilityLabel(DeckTheme.label(for: urgent))
                    }
                }
                if let github = project.github {
                    Text(github.label)
                        .font(DeckTheme.mono)
                        .foregroundStyle(DeckTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    Label(live > 0 ? "ルーム \(live)" : "ルームなし", systemImage: "bubble.left.and.bubble.right")
                    Label("リンク \(project.links.count)", systemImage: "link")
                }
                .labelStyle(SmallLabelStyle())
                .font(DeckTheme.caption)
                .foregroundStyle(DeckTheme.tertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectIcon: View {
    let active: Bool

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: 16))
            .foregroundStyle(active ? DeckTheme.accent : DeckTheme.tertiary)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.inputSurface))
            .accessibilityHidden(true)
    }
}

struct SmallLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

/// 左の一覧の「リンク」: 全プロジェクト横断のリンク（プロジェクトごと・ピンを先頭に）。押すと Safari で開く。
struct LinkOverviewList: View {
    @Bindable var model: AppModel
    @Binding var route: [DeckRoute]
    let regular: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ProjectsStatusView(model: model, emptyTitle: "リンクがありません",
                                   emptyDetail: "Mac の claude-deck のディレクトリの詳細か、設定画面の「リンク」で登録すると、ここに出ます。",
                                   isEmpty: { $0.linkSections.isEmpty })
                ForEach(model.projects?.linkSections ?? []) { project in
                    // 節ごとにまとめ、行の id（位置）が他の節とぶつからないようにする。
                    VStack(alignment: .leading, spacing: 2) {
                        header(project)
                        ForEach(Array(project.links.enumerated()), id: \.offset) { _, link in
                            LinkRow(link: link)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    private func header(_ project: RemoteProject) -> some View {
        HStack(spacing: 6) {
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DeckTheme.heading)
                .lineLimit(1)
            if !project.isActive {
                Text(project.status.label).font(.system(size: 11)).foregroundStyle(DeckTheme.tertiary)
            }
            Spacer(minLength: 8)
            SidebarRowLink(step: .project(project.id), route: $route, regular: regular) {
                Label("詳細", systemImage: "folder")
                    .labelStyle(SmallLabelStyle())
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel("\(project.name) の詳細")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}
