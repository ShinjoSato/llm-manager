import SwiftUI
import MonitorKit

/// プロジェクトの枠の見出し（名前・いちばん急ぐ状態・件数・開閉・そのプロジェクトで起動する「+」）。
struct ProjectSectionHeader: View {
    let section: ProjectRoomSection
    let collapsed: Bool
    let onToggle: () -> Void
    /// 「その他」は起動先が無いので nil。
    let onLaunch: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ChatTheme.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(section.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(section.isOther ? ChatTheme.secondary : ChatTheme.heading)
                        .lineLimit(1)
                    if let status = section.urgentStatus { SectionStatusBadge(status: status) }
                    Text("\(section.ids.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatTheme.tertiary)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "枠を開く" : "枠を畳む")
            .accessibilityLabel("\(section.name)（\(section.ids.count) 件）")
            if let onLaunch {
                Button(action: onLaunch) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ChatTheme.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().stroke(ChatTheme.inputBorder))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("「\(section.name)」で Claude Code を起動（動いているルームがあればそこへ移る）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(SectionFrame(top: true, bottom: collapsed))
    }
}

/// 見出しの状態。要対応は色の地で目立たせる。
private struct SectionStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        let color = ChatTheme.color(for: status)
        let attention = RoomPhase(status: status) == .attention
        Text(ChatTheme.label(for: status))
            .font(.system(size: 10, weight: attention ? .bold : .medium))
            .foregroundStyle(color)
            .padding(.horizontal, attention ? 6 : 0)
            .padding(.vertical, attention ? 1 : 0)
            .background(Capsule().fill(color.opacity(attention ? 0.18 : 0)))
            .fixedSize()
    }
}

/// 枠の地。見出しと行を別々の段で描くので、上下の端だけ角を丸めて 1 つの枠に見せる。
struct SectionFrame: View {
    var top = false
    var bottom = false

    var body: some View {
        let radius: CGFloat = 12
        UnevenRoundedRectangle(topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                               bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0)
            .fill(ChatTheme.background)
    }
}
