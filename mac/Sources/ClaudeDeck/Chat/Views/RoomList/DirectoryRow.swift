import SwiftUI
import MonitorKit

/// 「ディレクトリ」の 1 行（印・名前・パスの末尾・動いているセッションの件数といちばん急ぐ状態・LP のサムネイル）。
struct DirectoryRow: View, Equatable {
    let directory: ProjectDirectory
    let selected: Bool
    /// 確認の日を過ぎてまだ開いていないリンクがあるか（要対応のバッジとは別の控えめな印）。
    let dueLinks: Bool

    var body: some View {
        let project = directory.project
        HStack(alignment: .top, spacing: 10) {
            ProjectBadgeView(badge: ProjectBadge.resolve(project: project), size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                    if dueLinks {
                        Circle()
                            .fill(ChatTheme.permission)
                            .frame(width: 6, height: 6)
                            .help("確認が必要なリンクがあります")
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    if directory.liveCount > 0 {
                        Text("\(directory.liveCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatTheme.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(ProjectDirectories.pathTail(project.path))
                        .font(ChatTheme.mono.weight(.regular))
                        .foregroundStyle(ChatTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if let status = directory.urgentStatus { DirectoryStatusBadge(status: status) }
                }
            }
            SiteThumbnailView(project: project)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ChatTheme.selectedRow : .clear))
        // 休止・保管は選べるが目立たせない。
        .opacity(directory.isActive ? 1 : 0.55)
        .help(project.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibilityText: String {
        var parts = [directory.project.name, directory.project.path]
        if !directory.isActive { parts.append(directory.project.status.label) }
        if let status = directory.urgentStatus { parts.append("\(ChatTheme.label(for: status))・\(directory.liveCount) 件") }
        if dueLinks { parts.append("確認が必要なリンクあり") }
        return parts.joined(separator: "、")
    }
}

/// いちばん急ぐ状態。要対応は色の地で目立たせる。
struct DirectoryStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        let color = ChatTheme.color(for: status)
        let attention = RoomPhase(status: status) == .attention
        Text(ChatTheme.label(for: status))
            .font(.system(size: 10, weight: attention ? .bold : .medium))
            .foregroundStyle(color)
            .padding(.horizontal, attention ? 6 : 0)
            .padding(.vertical, attention ? 1 : 0)
            .background(Capsule().fill(attention ? ChatTheme.attentionBadge(for: status) : .clear))
            .fixedSize()
    }
}

/// LP のサムネイル（書き出しが無ければ出さない）。行は Equatable で描き直しを絞るので、撮れた時はここだけが描き直る。
struct SiteThumbnailView: View {
    let project: ManagedProject
    private var store: SiteThumbnailStore { SiteThumbnailStore.shared }

    var body: some View {
        // 空の Group では onAppear が来ないので、無い時も幅 0 の場所を置く。
        ZStack {
            if let image = store.images[project.path] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 40, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(ChatTheme.border))
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: project.site?.path ?? "") { store.request(project) }
        .onAppear { store.request(project) }
    }
}
