import DeckCore

/// claude の終了になる操作（Esc が終了になるメニューの取り消し・trust 確認の「No, exit」）を送る前に出す確認。
struct ExitConfirmation: Equatable {
    var menuId: String
    /// 選ぶ選択肢の位置。nil は取り消し（Esc）。
    var choice: Int?
    /// 選ぶ選択肢の名前（確認の文言に出す）。
    var label: String?

    static let title = "claude を終了しますか？"

    static func cancel(_ menuId: String) -> ExitConfirmation {
        ExitConfirmation(menuId: menuId, choice: nil, label: nil)
    }

    static func choice(_ index: Int, in menu: RemoteMenu) -> ExitConfirmation {
        ExitConfirmation(menuId: menu.menuId, choice: index, label: menu.label(of: index))
    }

    /// 押した選択肢が終了になる（mac の印がある）時だけ確認を返す。
    static func needed(choosing index: Int, in menu: RemoteMenu) -> ExitConfirmation? {
        menu.choiceExits(index) ? choice(index, in: menu) : nil
    }

    var actionTitle: String {
        guard choice != nil else { return "終了する（Esc）" }
        return "終了する（\(label ?? "この選択肢")）"
    }

    var message: String {
        guard choice != nil else { return "このメニューで Esc を押すと、取り消しではなく Claude Code の終了になります。" }
        return "「\(label ?? "この選択肢")」を選ぶと、Claude Code が終了します。"
    }
}
