import SwiftUI
import MonitorKit

/// 「ディレクトリ」の 1 行（色の点・名前・パスの末尾・動いているセッションの件数といちばん急ぐ状態）。
struct DirectoryRow: View, Equatable {
    let directory: ProjectDirectory
    let selected: Bool

    var body: some View {
        let project = directory.project
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(ChatTheme.avatarColor(for: project.name))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
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
