import SwiftUI
import MonitorKit

/// 選択メニューは出ているが中身を読み取れない時のカード。閉じる（Esc）ことだけはできる。
struct UnreadableMenuCard: View {
    let menu: UnreadableMenu
    /// 送信中と一言を読む先。このカードの印の分だけを見る。
    let board: PromptCardBoard
    let key: String
    /// claude の版（確かめていない版なら一言を出す）。
    var claudeVersion: String? = nil
    /// 押した時の写しを渡す。
    let onCancel: (UnreadableMenu) -> Void
    @State private var exitMenu: UnreadableMenu?
    /// 送信中・一言の期限で描き直すための時計。
    @State private var clock = 0

    private var identity: String { PromptCardIdentity.unreadable(menu) }
    private var busy: Bool {
        _ = clock
        return board.isCardBusy(key: key, identity: identity)
    }
    private var notice: String? {
        _ = clock
        return board.notice(key: key, identity: identity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "list.bullet.circle.fill", title: menu.isDialog ? "ダイアログ" : "選択肢")
            Text(message)
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
            if let notice {
                Text(notice).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            }
            UntestedVersionNote(version: claudeVersion)
            HStack(spacing: 8) {
                CardEscapeButton(exits: menu.cancelExits) {
                    if menu.cancelExits { exitMenu = menu } else { onCancel(menu) }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
        .cardFrame()
        .exitConfirmation(presenting: $exitMenu, onExit: onCancel)
        .cardClock(next: board.nextChange(key: key, identity: identity)) { clock &+= 1 }
        .onAppear { board.cardAppeared(key: key, identity: identity, kind: "unreadable") }
    }

    private var message: String {
        if menu.isDialog {
            return "端末でダイアログが開いています（画面からは読み取れません）。開いている間は送信がダイアログに取られるので送りません。閉じると Claude Code は取り消しとして扱います。"
        }
        return menu.cancelExits
            ? "端末に選択肢が出ていますが、内容を読み取れませんでした。このメニューで Esc を押すと Claude Code が終了します。"
            : "端末に選択肢が出ていますが、内容を読み取れませんでした。閉じると Claude Code は取り消しとして扱います。"
    }
}
