import DeckCore
import SwiftUI

/// カードで答えられない時の逃げ道: Mac がホストしている端末の今の表示を見ながら、決まったキーだけを 1 回ずつ送る。
struct TerminalScreenSheet: View {
    @Bindable var model: AppModel
    let roomId: String
    let roomName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewer = UUID()
    @State private var confirmingExit = false

    private var watch: AppModel.TerminalWatch? {
        model.terminalWatch?.viewer == viewer ? model.terminalWatch : nil
    }

    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mac の端末の今の表示です（1 秒弱ごとに取り直し、変わった時だけ描き直します）。カードで答えられない時に、下のボタンでキーを 1 回ずつ送れます。文字の入力はできません。")
                    .font(DeckTheme.caption)
                    .foregroundStyle(DeckTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = watch?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("terminal-problem")
                }
                TerminalScreenText(screen: watch?.screen, regular: regular)
                    .opacity(watch?.problem == nil ? 1 : 0.5)
                TerminalKeyPad(regular: regular, enabled: canSend, onKey: press)
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DeckTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DeckTheme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("端末の画面").font(.system(size: 15, weight: .bold)).foregroundStyle(DeckTheme.heading)
                        Text(roomName).font(.system(size: 11, design: .monospaced)).foregroundStyle(DeckTheme.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }.accessibilityIdentifier("terminal-close")
                }
            }
        }
        // Esc は端末に送るキーなので、下へのスワイプでもうっかり閉じない（「閉じる」で閉じる）。
        .interactiveDismissDisabled()
        .presentationDetents([.large])
        .modifier(WideSheetSizing())
        .onAppear { model.watchTerminal(roomId: roomId, viewer: viewer) }
        .onDisappear { model.stopWatchingTerminal(viewer: viewer) }
        .confirmationDialog("claude を終了しますか？", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("終了する（Esc）", role: .destructive) { model.sendTerminalKey(.escape, confirmExit: true) }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("このメニューで Esc を押すと、取り消しではなく Claude Code の終了になります。")
        }
    }

    private var canSend: Bool {
        guard let watch else { return false }
        return !watch.sending && watch.screen != nil && watch.problem == nil && model.connection.isConnected
    }

    /// Esc で claude が終わるメニューでは、カードと同じく確かめてから送る。
    private func press(_ key: RemoteTerminalKey) {
        if key == .escape, watch?.screen?.escapeExits == true {
            confirmingExit = true
            return
        }
        model.sendTerminalKey(key)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if watch?.sending == true {
                ProgressView().controlSize(.small)
                Text("送信中…").foregroundStyle(DeckTheme.secondary)
            } else if let notice = watch?.notice {
                Text(notice.text)
                    .foregroundStyle(notice.isError ? DeckTheme.error : DeckTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terminal-notice")
            }
            Spacer(minLength: 8)
            if let captured = watch?.screen?.capturedAt {
                Text("表示が変わった時刻 \(Self.timeFormatter.string(from: Date(timeIntervalSince1970: captured / 1000)))")
                    .foregroundStyle(DeckTheme.tertiary)
                    .monospacedDigit()
            }
        }
        .font(DeckTheme.caption)
        .frame(minHeight: 18)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// iPad では端末の 1 行がなるべく収まるよう、ページの大きさのシートにする（iOS 18 から。iOS 17 は標準のシート）。
private struct WideSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

/// 端末の表示（等幅・折り返さない）。iPad では大きめの文字で広く、iPhone では横にスクロールして読む。
private struct TerminalScreenText: View {
    let screen: RemoteTerminalScreen?
    let regular: Bool

    var body: some View {
        let text = screen.map { $0.lines.isEmpty ? " " : $0.lines.joined(separator: "\n") }
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let text {
                        Text(text)
                            .font(.system(size: regular ? 13 : 10.5, design: .monospaced))
                            .foregroundStyle(DeckTheme.text)
                            .textSelection(.enabled)
                            .fixedSize()
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("端末の表示を取っています…").font(DeckTheme.caption).foregroundStyle(DeckTheme.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(DeckTheme.codeSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeckTheme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("端末の表示")
        .accessibilityValue(text ?? "読み込み中")
        .accessibilityIdentifier("terminal-screen")
    }
}

/// 送れるキーのボタン（mac のシートと同じ表）。
private struct TerminalKeyPad: View {
    let regular: Bool
    let enabled: Bool
    let onKey: (RemoteTerminalKey) -> Void

    private static let arrows: [RemoteTerminalKey] = [.left, .up, .down, .right]
    private static let controls: [RemoteTerminalKey] = [.enter, .escape, .tab, .space]
    private static let digits: [RemoteTerminalKey] = [.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9]

    var body: some View {
        VStack(spacing: 6) {
            if regular {
                HStack(spacing: 6) {
                    row(Self.arrows)
                    Divider().frame(height: 26).padding(.horizontal, 4)
                    row(Self.controls)
                }
            } else {
                HStack(spacing: 6) { row(Self.arrows) }
                HStack(spacing: 6) { row(Self.controls) }
            }
            HStack(spacing: regular ? 6 : 4) { row(Self.digits) }
        }
        .frame(maxWidth: regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
    }

    private func row(_ keys: [RemoteTerminalKey]) -> some View {
        ForEach(keys, id: \.self) { key in
            Button { onKey(key) } label: {
                Text(key.label)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(enabled ? DeckTheme.text : DeckTheme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.inputSurface))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.inputBorder))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(key.accessibilityName)
            .accessibilityHint("端末に 1 回送る")
            .accessibilityIdentifier("terminal-key-\(key.rawValue)")
        }
    }
}

/// カードの「端末の画面」ボタン。カードが送信中のまま止まっても押せるよう、カードの無効化の外に置く。
struct CardTerminalButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("端末の画面", systemImage: "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DeckTheme.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(DeckTheme.inputSurface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeckTheme.inputBorder))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("今の端末の表示を見て、矢印・Enter・Esc などのキーを直接送る")
        .accessibilityIdentifier("card-terminal")
    }
}
