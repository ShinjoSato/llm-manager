import SwiftUI
import MonitorKit

/// 「端末の画面」を開く口。会話の画面が渡し、無ければボタンを出さない。
struct OpenTerminalScreenAction {
    let open: @MainActor (HostedSession) -> Void

    @MainActor func callAsFunction(_ session: HostedSession) { open(session) }
}

extension EnvironmentValues {
    @Entry var openTerminalScreen: OpenTerminalScreenAction? = nil
}

/// カードで答えられない時の逃げ道: ホスト中の端末の今の表示を見ながら、決まったキーだけを 1 回ずつ直接送るシート。
struct TerminalScreenSheet: View {
    let session: HostedSession
    let roomName: String
    /// 押したキーを送って結果を返す（権限の回答中・選択肢の移動中は送らない）。
    let send: (TerminalKey) -> RemoteActionResult
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var notice: TerminalKeyNotice?
    @State private var exitKey: TerminalKey?
    @FocusState private var focused: Bool

    /// 端末の表示を読み直す間隔。カードの監視（0.3 秒）とそろえる。
    static let refreshInterval: Duration = .milliseconds(300)

    var body: some View {
        TerminalScreenPanel(roomName: roomName, lines: lines, running: session.isRunning, notice: shownNotice,
                            keyboardActive: focused, onKey: press, onFocus: { focused = true },
                            onCopy: { SystemActions.copy(lines.joined(separator: "\n")) }, onClose: { dismiss() })
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            // 押しっぱなしの連打で行き過ぎないよう、押した時だけ送る。
            .onKeyPress(phases: .down) { keyPress in
                guard keyPress.modifiers.isDisjoint(with: [.command, .control, .option]),
                      let key = TerminalKey(keyCharacter: keyPress.key.character),
                      // Shift+Tab は Claude Code ではモードの切り替えなので、ただの Tab として送らない。
                      !(key == .tab && keyPress.modifiers.contains(.shift)) else { return .ignored }
                press(key)
                return .handled
            }
            .onAppear { focused = true }
            // Esc は端末に送るキーなので、シートは「閉じる」（⌘W）でだけ閉じる。
            .interactiveDismissDisabled()
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
            .exitConfirmation(presenting: $exitKey) { deliver($0) }
    }

    /// 「入力欄を消す」を押した後に消し終えたら、その結末を出す。
    private var shownNotice: TerminalKeyNotice? {
        guard let notice, notice.key == .clearInput, notice.result.ok, let last = session.lastClear, last.at >= notice.at,
              let text = ChatOutbox.clearMessage(last.outcome) else { return notice }
        let result: RemoteActionResult = last.outcome == .cleared ? .success("cleared") : .failure("clear", text)
        return TerminalKeyNotice(key: .clearInput, result: result, at: last.at, detail: text)
    }

    /// Esc で claude が終わるメニューでは、カードと同じく確かめてから送る。
    private var escapeExits: Bool {
        session.menuPrompt?.cancelExits == true || session.unreadableMenu?.cancelExits == true
    }

    private func press(_ key: TerminalKey) {
        if key == .escape, escapeExits {
            exitKey = key
            return
        }
        deliver(key)
    }

    private func deliver(_ key: TerminalKey) {
        let result = send(key)
        notice = TerminalKeyNotice(key: key, result: result, at: Date())
        focused = true
    }

    private func refresh() {
        let next = session.screenText()
        if next != lines { lines = next }
    }
}

/// 直前に押したキーの結果。
struct TerminalKeyNotice: Equatable {
    let key: TerminalKey
    let result: RemoteActionResult
    let at: Date
    /// 送った後の結末（入力欄を消し終えた等）。あればこちらを出す。
    var detail: String? = nil

    var text: String {
        if let detail { return detail }
        guard result.ok else { return result.message ?? "送れませんでした。" }
        return key == .clearInput ? "入力欄を消すキーを送っています（\(ChatTime.seconds(at))）" : "\(key.label) を送りました（\(ChatTime.seconds(at))）"
    }
}

/// シートの中身（端末の表示・キーのボタン・結果の一言）。描くだけで、送るのは `onKey`。
struct TerminalScreenPanel: View {
    let roomName: String
    let lines: [String]
    let running: Bool
    let notice: TerminalKeyNotice?
    /// キーボードの押下がこのシートに届く状態か。
    let keyboardActive: Bool
    let onKey: (TerminalKey) -> Void
    let onFocus: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void
    /// 見本の描画で外観を固定する時だけ渡す（既定は設定のテーマに追従）。
    var theme: DeckTheme? = nil

    /// 端末の 1 行（約 160 桁）がなるべく横に収まる大きさ。
    static let screenFont = Font.system(size: 11, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("今の端末の表示です（0.3 秒ごとに更新）。カードで答えられない時に、下のボタンかキーボード（矢印・Return・Esc・Tab・Space・1〜9）で 1 回ずつキーを送れます。文字の入力はできません。「入力欄を消す」は端末の入力欄を空にします（作業は止めません）。")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            screen
            keys
            footer
        }
        .padding(18)
        .frame(minWidth: 720, idealWidth: 1080, maxWidth: .infinity, minHeight: 480, idealHeight: 700, maxHeight: .infinity)
        .background(ChatTheme.background)
        .environment(\.colorScheme, ChatTheme.colorScheme(for: theme ?? AppearanceSettings.shared.theme))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(ChatTheme.permission)
            Text("端末の画面").font(ChatTheme.headline).foregroundStyle(ChatTheme.heading)
            Text(roomName)
                .font(ChatTheme.mono)
                .foregroundStyle(ChatTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !running {
                Text("claude は終了しました").statusCapsule(ChatTheme.tertiary)
            }
            Spacer(minLength: 12)
            Button(action: onCopy) { CardButtonLabel(title: "表示をコピー") }
                .buttonStyle(.plain)
                .help("今の端末の表示を文字としてクリップボードに写す")
            Button(action: onClose) { CardButtonLabel(title: "閉じる") }
                .buttonStyle(.plain)
                .keyboardShortcut("w", modifiers: .command)
                .help("閉じる（⌘W）。Esc は端末に送るキーなので閉じません")
        }
    }

    private var screen: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                // 端末と同じく上から詰める。常に出るスクロールバーの分だけ下限を控え、短い時に先頭が隠れないようにする。
                Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
                    .font(Self.screenFont)
                    .foregroundStyle(ChatTheme.text)
                    .fixedSize()
                    .padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: max(0, geometry.size.height - 20), alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .roundedSurface(10, fill: ChatTheme.codeSurface, stroke: keyboardActive ? ChatTheme.permission.opacity(0.6) : ChatTheme.border)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .accessibilityLabel("端末の表示")
        .accessibilityValue(lines.joined(separator: "\n"))
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(TerminalKey.all.prefix(4)), id: \.self) { key in TerminalKeyButton(key: key, enabled: running, action: onKey) }
                Divider().frame(height: 22).padding(.horizontal, 4)
                ForEach(Array(TerminalKey.all.dropFirst(4).prefix(4)), id: \.self) { key in TerminalKeyButton(key: key, enabled: running, action: onKey) }
            }
            HStack(spacing: 6) {
                ForEach(Array(TerminalKey.all.dropFirst(8)), id: \.self) { key in TerminalKeyButton(key: key, enabled: running, action: onKey) }
                Divider().frame(height: 22).padding(.horizontal, 4)
                TerminalKeyButton(key: .clearInput, enabled: running, action: onKey)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice {
                Text(notice.text)
                    .font(ChatTheme.caption)
                    .foregroundStyle(notice.result.ok ? ChatTheme.secondary : ChatTheme.error)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Text(keyboardActive ? "キーボードからも送れます" : "端末の表示をクリックするとキーボードからも送れます")
                .font(ChatTheme.caption)
                .foregroundStyle(ChatTheme.tertiary)
        }
        .frame(minHeight: 18)
    }
}

/// 送れるキー 1 つ分のボタン。
private struct TerminalKeyButton: View {
    let key: TerminalKey
    let enabled: Bool
    let action: (TerminalKey) -> Void
    @State private var hovering = false

    var body: some View {
        Button { action(key) } label: {
            Text(key.label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(enabled ? ChatTheme.text : ChatTheme.tertiary)
                .padding(.horizontal, 10)
                .frame(minWidth: 38, minHeight: 30)
                .roundedSurface(8, fill: hovering && enabled ? ChatTheme.selectedRow : ChatTheme.inputSurface, stroke: ChatTheme.inputBorder)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(key == .clearInput ? "端末の入力欄を空にする（Ctrl-E・Ctrl-K・Ctrl-U を空になるまで送る。作業は中断しない）" : "\(key.label) を端末に 1 回送る")
        .onHover { hovering = $0 }
    }
}

/// カードの「端末の画面」ボタン。カードが送信中のまま止まっても押せるよう、カードの無効化の外に置く。
struct CardTerminalButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .medium))
                Text("端末の画面").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(ChatTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .roundedSurface(9, fill: ChatTheme.quietButton, stroke: ChatTheme.quietButtonBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("今の端末の表示を見て、矢印・Enter・Esc などのキーを直接送る（カードで答えられない時に）")
    }
}
