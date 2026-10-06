import SwiftUI
import MonitorKit

/// 選択メニューは出ているが中身を読み取れない時のカード。閉じる（Esc）ことだけはできる。
struct UnreadableMenuCard: View {
    let menu: UnreadableMenu
    let busy: Bool
    /// 押した時の写しを渡す。
    let onCancel: (UnreadableMenu) -> Void
    @State private var exitMenu: UnreadableMenu?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "list.bullet.circle.fill", title: "選択肢")
            Text(menu.cancelExits
                 ? "端末に選択肢が出ていますが、内容を読み取れませんでした。このメニューで Esc を押すと Claude Code が終了します。"
                 : "端末に選択肢が出ていますが、内容を読み取れませんでした。閉じると Claude Code は取り消しとして扱います。")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            HStack(spacing: 8) {
                Button {
                    if menu.cancelExits { exitMenu = menu } else { onCancel(menu) }
                } label: {
                    CardButtonLabel(title: menu.cancelExits ? "終了（Esc）" : "キャンセル（Esc）")
                }
                .buttonStyle(.plain)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
        .cardFrame()
        .exitConfirmation(presenting: $exitMenu, onExit: onCancel)
    }
}
