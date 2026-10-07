import SwiftUI
import MonitorKit

/// ルーム 1 行。描いている値だけで比べ、状態が変われば必ず描き直す。
struct RoomRow: View, Equatable {
    let room: Room
    let selected: Bool

    static func == (lhs: RoomRow, rhs: RoomRow) -> Bool {
        lhs.selected == rhs.selected && lhs.room.id == rhs.room.id && lhs.room.name == rhs.room.name
            && lhs.room.branch == rhs.room.branch && lhs.room.status == rhs.room.status && lhs.room.line == rhs.room.line
            && lhs.room.activityAt == rhs.room.activityAt && lhs.room.unread == rhs.room.unread
            && lhs.room.isExternal == rhs.room.isExternal
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelAvatar(status: room.status, size: 36, hidesFromAccessibility: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                    if room.isExternal { ExternalTag() }
                    Spacer(minLength: 4)
                    Text(ChatTime.short(room.activityDate))
                        .font(.system(size: 11))
                        .foregroundStyle(ChatTheme.tertiary)
                }
                if let branch = room.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .font(ChatTheme.mono.weight(.regular))
                    .foregroundStyle(ChatTheme.secondary)
                }
                HStack(spacing: 4) {
                    Text(ChatTheme.label(for: room.status))
                        .foregroundStyle(ChatTheme.color(for: room.status))
                        .fixedSize()
                    if !room.line.isEmpty {
                        Text("· \(Self.oneLine(room.line))")
                            .foregroundStyle(ChatTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if room.unread > 0 {
                        Text("\(min(room.unread, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ChatTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(ChatTheme.accent))
                    }
                }
                .font(ChatTheme.caption)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ChatTheme.selectedRow : .clear))
    }

    static func oneLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // 一覧では装飾記号がノイズになるので落とす。
        return first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

struct ExternalTag: View {
    var label = "外部"

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ChatTheme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(ChatTheme.externalTagFill))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.externalTagBorder))
            .help("アプリの外（VS Code・別ターミナル等）で動いているセッション")
    }
}

/// プロジェクトのアイコン（セッションを持たないプロジェクト一覧用）。印を渡せば縁取りの丸 + SF Symbol、無ければ頭文字の角丸四角。
struct RoomAvatar: View {
    let name: String
    let size: CGFloat
    var badge: ProjectBadge? = nil

    var body: some View {
        if let badge {
            ProjectBadgeView(badge: badge, size: size)
        } else {
            let color = ChatTheme.avatarColor(for: name)
            Text(RoomGrouping.initial(of: name))
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(color.opacity(0.28)))
        }
    }
}

/// プロジェクトの印: 同じ色の薄い塗りの丸に、中央に色のアイコン。一覧・詳細の見出し・「+」・設定で同じ絵。
struct ProjectBadgeView: View {
    let badge: ProjectBadge
    let size: CGFloat

    var body: some View {
        let color = ChatTheme.avatarColor(for: badge.colorKey)
        Image(systemName: badge.symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.14)))
            .accessibilityHidden(true)
    }
}
