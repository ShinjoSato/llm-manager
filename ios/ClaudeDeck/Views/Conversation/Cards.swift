import DeckCore
import SwiftUI

/// 会話の末尾に出す要対応のカード（権限・選択肢）。押した時に見ていた ID のまま送る（替わっていれば mac が断る）。
struct CardView: View {
    @Bindable var model: AppModel
    let room: RemoteRoom
    let card: RoomCard

    var body: some View {
        let busy = model.isBusy(room)
        switch card {
        case .channels(let permissions):
            ForEach(permissions) { permission in
                PermissionCard(toolName: permission.toolName, description: permission.description,
                               lines: permission.inputPreview.isEmpty ? [] : [permission.inputPreview], busy: busy) { allow in
                    model.decide(room, permission, allow: allow)
                }
            }
        case .terminalPermission(let prompt):
            PermissionCard(toolName: room.session?.currentTool ?? prompt.title, description: prompt.title, lines: prompt.lines,
                           busy: busy) { allow in
                model.answerTerminal(room, prompt, allow: allow)
            }
        case .menu(let menu):
            MenuCard(menu: menu, busy: busy) { choice, confirmExit in
                model.answerMenu(room, menu, choice: choice, confirmExit: confirmExit)
            } onMoveTab: { direction in
                model.moveTab(room, menu, direction)
            }
            .id(menu.menuId)
        case .unreadableMenu(let menu):
            UnreadableMenuCard(menu: menu, busy: busy) { confirmExit in
                model.dismiss(room, menu, confirmExit: confirmExit)
            }
            .id(menu.menuId)
        case .channelsMissing(let toolName):
            ChannelsMissingCard(toolName: toolName)
        }
    }
}

struct PermissionCard: View {
    let toolName: String
    let description: String
    let lines: [String]
    let busy: Bool
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CardTitle(symbol: "exclamationmark.shield.fill", title: "権限の確認")
                Text(toolName)
                    .font(DeckTheme.mono.weight(.semibold))
                    .foregroundStyle(DeckTheme.permission)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(DeckTheme.permission.opacity(0.14)))
            }
            if !description.isEmpty, description != toolName {
                Text(description).font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
            }
            if !lines.isEmpty {
                CardCode(text: lines.prefix(10).joined(separator: "\n"))
            }
            HStack(spacing: 10) {
                Button { onDecide(true) } label: {
                    Text("許可")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DeckTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("permission-allow")
                Button { onDecide(false) } label: {
                    CardButtonLabel(title: "拒否")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("permission-deny")
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
            if busy { SendingIndicator() }
        }
        .cardFrame()
    }
}

/// 端末に出ている選択メニュー（plan の承認・選択式の質問・trust 確認など）。
struct MenuCard: View {
    let menu: RemoteMenu
    let busy: Bool
    /// 選択肢の位置。nil は取り消し（Esc）。2 つ目は終了の確認を済ませたか。
    let onChoose: (Int?, Bool) -> Void
    let onMoveTab: (RemoteTabDirection) -> Void
    @State private var confirmingExit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "list.bullet.circle.fill", title: "選択肢")
            if let tabs = menu.tabs, !tabs.tabs.isEmpty {
                MenuTabBar(tabs: tabs, onMove: onMoveTab)
            }
            if !menu.context.isEmpty {
                CardCode(text: menu.context.joined(separator: "\n"))
            }
            if !menu.question.isEmpty {
                Text(menu.question)
                    .font(DeckTheme.body.weight(.semibold))
                    .foregroundStyle(DeckTheme.heading)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(menu.options, id: \.index) { option in
                    MenuOptionRow(option: option, isCursor: option.index == menu.cursor) { onChoose(option.index, false) }
                }
            }
            if menu.isMultiSelect {
                hint(menu.options.contains(where: \.isSubmit)
                     ? "複数選択: 押すとチェックを切り替えます。選び終えたら「Submit」/「Next」を押して先へ進みます。"
                     : "複数選択: 押すとチェックを切り替えます。")
            }
            if menu.isReview {
                hint("回答を送るには「Submit answers」を押します。「Cancel」は質問ごと取り消します。直す時は「← 前の問い」で戻ります。")
            }
            if menu.options.contains(where: { !$0.selectable }) {
                hint("文字を入力する選択肢はここからは選べません。「キャンセル」で閉じてから、下の入力欄で伝えてください。")
            }
            MenuCancelButton(cancelExits: menu.cancelExits, confirmingExit: $confirmingExit) { onChoose(nil, false) }
                .accessibilityIdentifier("menu-cancel")
            if busy { SendingIndicator() }
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .cardFrame()
        .exitConfirmation(isPresented: $confirmingExit) { onChoose(nil, true) }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuOptionRow: View {
    let option: RemoteMenuOption
    /// 端末で今 ❯ が付いている行。
    let isCursor: Bool
    let action: () -> Void

    var body: some View {
        let disabled = !option.selectable
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.number.map { "\($0)." } ?? (option.isSubmit ? "→" : "•"))
                    .font(DeckTheme.mono.weight(.semibold))
                    .foregroundStyle(DeckTheme.permission)
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? DeckTheme.permission : DeckTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.isSubmit ? (option.label == "Next" ? "Next（次の問いへ）" : "Submit（回答の確認へ）") : option.label)
                        .font(.system(size: 14.5, weight: option.isSubmit ? .bold : .medium))
                        .foregroundStyle(disabled ? DeckTheme.tertiary : DeckTheme.text)
                        .multilineTextAlignment(.leading)
                    ForEach(Array(option.detail.enumerated()), id: \.offset) { _, line in
                        Text(line).font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if disabled {
                    Text("入力は対象外").font(DeckTheme.caption).foregroundStyle(DeckTheme.tertiary)
                } else if isCursor {
                    Text("選択中").font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isCursor && !disabled ? DeckTheme.permission.opacity(0.6) : DeckTheme.inputBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier("menu-option-\(option.index)")
    }
}

/// AskUserQuestion の問いのタブ。今のタブを強調し、← / → で移る。
private struct MenuTabBar: View {
    let tabs: RemoteMenuTabs
    let onMove: (RemoteTabDirection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.offset) { index, tab in
                        chip((tab.answered ? "☒ " : "☐ ") + tab.title, current: tabs.current == index)
                    }
                    if tabs.hasSubmit { chip("✔ Submit", current: tabs.current == tabs.tabs.count) }
                }
            }
            HStack(spacing: 8) {
                moveButton("← 前の問い", direction: .previous, enabled: tabs.canMovePrevious)
                moveButton(tabs.current.map { $0 + 1 >= tabs.tabs.count } == true && tabs.hasSubmit ? "回答の確認へ →" : "次の問い →",
                           direction: .next, enabled: tabs.canMoveNext)
            }
            if tabs.current == nil {
                Text("今のタブは読み取れませんでした").font(DeckTheme.caption).foregroundStyle(DeckTheme.tertiary)
            }
        }
    }

    private func chip(_ text: String, current: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: current ? .bold : .regular))
            .foregroundStyle(current ? DeckTheme.heading : DeckTheme.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(current ? DeckTheme.permission.opacity(0.25) : DeckTheme.inputSurface))
    }

    private func moveButton(_ title: String, direction: RemoteTabDirection, enabled: Bool) -> some View {
        Button { onMove(direction) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? DeckTheme.text : DeckTheme.tertiary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(DeckTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeckTheme.inputBorder))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 選択メニューは出ているが中身を読み取れない時。閉じる（Esc）ことだけはできる。
struct UnreadableMenuCard: View {
    let menu: RemoteUnreadableMenu
    let busy: Bool
    /// 引数は終了の確認を済ませたか。
    let onCancel: (Bool) -> Void
    @State private var confirmingExit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(symbol: "list.bullet.circle.fill", title: "選択肢")
            Text(menu.cancelExits
                 ? "端末に選択肢が出ていますが、内容を読み取れませんでした。このメニューで Esc を押すと Claude Code が終了します。"
                 : "端末に選択肢が出ていますが、内容を読み取れませんでした。閉じると Claude Code は取り消しとして扱います。")
                .font(DeckTheme.caption)
                .foregroundStyle(DeckTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !menu.lines.isEmpty { CardCode(text: menu.lines.suffix(12).joined(separator: "\n")) }
            MenuCancelButton(cancelExits: menu.cancelExits, confirmingExit: $confirmingExit) { onCancel(false) }
            if busy { SendingIndicator() }
        }
        .disabled(busy)
        .cardFrame()
        .exitConfirmation(isPresented: $confirmingExit) { onCancel(true) }
    }
}

/// 外部セッションが権限待ちなのに確認が届いていない（Channels を載せていない）時の案内。
struct ChannelsMissingCard: View {
    let toolName: String?
    /// 権限待ちになった直後は確認が届く前なので、少し待ってから出す。
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(DeckTheme.permission)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("権限の確認待ち").font(.system(size: 14, weight: .bold)).foregroundStyle(DeckTheme.heading)
                            if let toolName, !toolName.isEmpty {
                                Text(toolName).font(DeckTheme.mono.weight(.semibold)).foregroundStyle(DeckTheme.permission)
                            }
                        }
                        Text("確認がまだ届いていません。Channels を載せていないセッションは、ここからは答えられません（Mac のターミナルで答えてください）。")
                            .font(DeckTheme.caption)
                            .foregroundStyle(DeckTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.permission.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeckTheme.permission.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            shown = true
        }
    }
}

private struct CardTitle: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(DeckTheme.permission)
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(DeckTheme.heading)
        }
    }
}

private struct CardCode: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(DeckTheme.mono)
                .foregroundStyle(DeckTheme.text)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DeckTheme.codeSurface))
    }
}

private struct CardButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DeckTheme.text)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeckTheme.inputBorder))
    }
}

/// 選択メニューの取り消し（Esc）。Esc が終了になるメニューでは先に確認を出す。
private struct MenuCancelButton: View {
    let cancelExits: Bool
    @Binding var confirmingExit: Bool
    let onCancel: () -> Void

    var body: some View {
        Button {
            if cancelExits { confirmingExit = true } else { onCancel() }
        } label: {
            CardButtonLabel(title: cancelExits ? "終了（Esc）" : "キャンセル（Esc）")
        }
        .buttonStyle(.plain)
    }
}

private struct SendingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("送信中…").font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
        }
    }
}

private extension View {
    /// 要対応のカードの枠（会話の末尾に amber で出す）。
    func cardFrame() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DeckTheme.permission.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeckTheme.permission, lineWidth: 1.5))
    }

    /// Esc が claude の終了になるメニューで、送る前に確かめる。
    func exitConfirmation(isPresented: Binding<Bool>, onExit: @escaping () -> Void) -> some View {
        confirmationDialog("claude を終了しますか？", isPresented: isPresented, titleVisibility: .visible) {
            Button("終了する（Esc）", role: .destructive, action: onExit)
            Button("やめる", role: .cancel) {}
        } message: {
            Text("このメニューで Esc を押すと、取り消しではなく Claude Code の終了になります。")
        }
    }
}
