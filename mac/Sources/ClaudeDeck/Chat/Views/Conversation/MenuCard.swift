import SwiftUI
import MonitorKit

/// 端末に出ている選択メニュー（plan の承認・選択式の質問・trust 確認など）のカード。権限カードと同じ位置に出す。
struct MenuCard: View {
    let menu: MenuPrompt
    let busy: Bool
    /// 直前の操作の結果（複数選択でチェックを切り替えた等）。
    let notice: String?
    /// 押した時のメニューと選択肢の位置。nil は取り消し（Esc）。
    let onChoose: (MenuPrompt, Int?) -> Void
    /// 押した時のメニューと、問いのタブを移る向き。
    let onMoveTab: (MenuPrompt, MenuTabMover.Direction) -> Void
    /// 終了の確認を開いた時のメニュー。確認中に差し替わっても、開いた時のメニューで照合する。
    @State private var exitMenu: MenuPrompt?

    /// 今の ❯ から自由入力の行をまたがないと届かない選択肢があるか。
    private var crossesFreeText: Bool {
        menu.options.indices.contains { index in
            guard !menu.options[index].isFreeText else { return false }
            let range = index > menu.cursor ? (menu.cursor + 1)..<index : (index + 1)..<max(index + 1, menu.cursor)
            return range.contains { menu.options[$0].isFreeText }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "list.bullet.circle.fill", title: "選択肢")
            if let tabs = menu.tabs, tabs.hasArrows {
                MenuTabBar(tabs: tabs, onCursorFreeText: menu.options.indices.contains(menu.cursor) && menu.options[menu.cursor].isFreeText) {
                    onMoveTab(menu, $0)
                }
            }
            if !menu.context.isEmpty {
                CardCode(text: menu.context.joined(separator: "\n"))
            }
            if !menu.question.isEmpty {
                Text(menu.question).font(ChatTheme.body.weight(.semibold)).foregroundStyle(ChatTheme.heading)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(menu.options.enumerated()), id: \.offset) { index, option in
                    MenuOptionRow(option: option, isCursor: index == menu.cursor) { onChoose(menu, index) }
                }
            }
            if menu.isMultiSelect {
                Text(menu.options.contains(where: \.isSubmit)
                     ? "複数選択: 押すとチェックを切り替えます。選び終えたら「Submit」/「Next」を押して先へ進みます。"
                     : "複数選択: 押すとチェックを切り替えます。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            if menu.isReview {
                Text("回答を送るには「Submit answers」を押します。「Cancel」は質問ごと取り消します。直す時は「← 前の問い」で戻ります。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            if menu.options.contains(where: \.isFreeText) {
                Text("文字を入力する選択肢はここからは選べません。「キャンセル」で閉じてから、下の入力欄で伝えてください。"
                     + (crossesFreeText ? "その行をまたぐ選択肢は、通り抜ける途中で端末の表示が読めなくなると Enter を押さずに止まります。" : ""))
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.secondary)
            }
            if let notice {
                Text(notice).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
            }
            HStack(spacing: 8) {
                CardEscapeButton(exits: menu.cancelExits) {
                    if menu.cancelExits { exitMenu = menu } else { onChoose(menu, nil) }
                }
                if busy { SendingIndicator() }
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .cardFrame()
        .exitConfirmation(presenting: $exitMenu) { onChoose($0, nil) }
    }
}

private struct MenuOptionRow: View {
    let option: MenuPrompt.Option
    /// 端末で今 ❯ が付いている行（Enter だけで決まる行）。
    let isCursor: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let disabled = option.isFreeText
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.number.map { "\($0)." } ?? (option.isSubmit ? "→" : "•"))
                    .font(ChatTheme.mono.weight(.semibold))
                    .foregroundStyle(ChatTheme.permission)
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? ChatTheme.permission : ChatTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.isSubmit ? (option.label == "Next" ? "Next（次の問いへ）" : "Submit（回答の確認へ）") : option.label)
                        .font(.system(size: 13, weight: option.isSubmit ? .bold : .medium))
                        .foregroundStyle(disabled ? ChatTheme.tertiary : ChatTheme.text)
                    ForEach(Array(option.detail.enumerated()), id: \.offset) { _, line in
                        Text(line).font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                    }
                }
                Spacer(minLength: 8)
                if disabled {
                    Text("入力は対象外").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                } else if isCursor {
                    Text("選択中").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedSurface(9, fill: hovering && !disabled ? ChatTheme.selectedRow : ChatTheme.inputSurface, stroke: isCursor && !disabled ? ChatTheme.permission.opacity(0.6) : ChatTheme.inputBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "文字の入力に移る選択肢はカードからは選べません" : option.label)
        .onHover { hovering = $0 }
    }
}

/// AskUserQuestion の問いのタブ。今のタブ（端末で背景色の付いたもの）を強調し、← / → で移る。
private struct MenuTabBar: View {
    let tabs: MenuTabs
    /// ❯ が文字入力の行にある（→ / ← が文字入力の操作になるので移れない）。
    let onCursorFreeText: Bool
    let onMove: (MenuTabMover.Direction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(tabs.tabs.enumerated()), id: \.offset) { index, tab in
                    chip((tab.answered ? "☒ " : "☐ ") + tab.title, current: tabs.current == index)
                }
                if tabs.hasSubmit {
                    chip("✔ Submit", current: tabs.isOnSubmit)
                }
            }
            HStack(spacing: 8) {
                moveButton("← 前の問い", direction: .previous, enabled: tabs.canMovePrevious)
                moveButton(tabs.current.map { $0 + 1 >= tabs.tabs.count } == true && tabs.hasSubmit ? "回答の確認へ →" : "次の問い →",
                           direction: .next, enabled: tabs.canMoveNext)
                if tabs.current == nil {
                    Text("今のタブは読み取れませんでした").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
                }
            }
            if onCursorFreeText {
                Text("端末の ❯ が文字入力の行にあるため、ここからはタブを移れません。").font(ChatTheme.caption).foregroundStyle(ChatTheme.tertiary)
            }
        }
    }

    private func chip(_ text: String, current: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: current ? .bold : .regular))
            .foregroundStyle(current ? ChatTheme.heading : ChatTheme.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(current ? ChatTheme.menuTabCurrent : ChatTheme.inputSurface))
    }

    private func moveButton(_ title: String, direction: MenuTabMover.Direction, enabled: Bool) -> some View {
        Button { onMove(direction) } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled && !onCursorFreeText ? ChatTheme.text : ChatTheme.tertiary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .inputFieldSurface(8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || onCursorFreeText)
    }
}
