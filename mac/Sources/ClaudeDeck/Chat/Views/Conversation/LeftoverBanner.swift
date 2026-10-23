import SwiftUI
import MonitorKit

/// 入らなかった本文の残りを確かめられるまで送らずにいる間、入力欄の上に出す案内と抜け道。
struct LeftoverBanner: View {
    let escape: LeftoverEscape
    let roomId: RoomID
    let session: HostedSession
    let outbox: ChatOutbox
    @Environment(\.openTerminalScreen) private var openTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatTheme.permission)
                VStack(alignment: .leading, spacing: 2) {
                    Text("前回入らなかった本文が端末の入力欄に残っているかもしれないため、送るのを止めています。")
                        .foregroundStyle(ChatTheme.text)
                    Text(ChatOutbox.leftoverDetail(escape))
                        .foregroundStyle(ChatTheme.secondary)
                }
                .font(ChatTheme.caption)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ForEach(LeftoverChoice.choices(strict: true, escape: escape), id: \.self) { choice in
                    Button { perform(choice) } label: { CardButtonLabel(title: Self.title(choice)) }
                        .buttonStyle(.plain)
                        .disabled(session.isSending)
                        .help(Self.help(choice))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.permission.opacity(0.10))
        .overlay(alignment: .top) { Rectangle().fill(ChatTheme.border).frame(height: 1) }
    }

    private func perform(_ choice: LeftoverChoice) {
        switch choice {
        case .openTerminal: openTerminal?(session)
        case .submitAsIs: outbox.submitLeftover(in: roomId)
        case .clearInput: outbox.clearTerminalInput(in: roomId)
        case .forceSend: outbox.confirmForceSend(in: roomId)
        }
    }

    static func title(_ choice: LeftoverChoice) -> String {
        switch choice {
        case .openTerminal: return "端末の画面"
        case .submitAsIs: return "そのまま送る（Enter）"
        case .clearInput: return "端末の入力欄を消す"
        case .forceSend: return "確かめられないまま送る…"
        }
    }

    static func help(_ choice: LeftoverChoice) -> String {
        switch choice {
        case .openTerminal: return "端末の今の表示を見て、入力欄に何が入っているかを確かめる"
        case .submitAsIs: return "端末の入力欄に入っている本文を Enter で送る（同じ本文と確かめられれば、この入力欄に戻した分は消す）"
        case .clearInput: return "端末の入力欄を空にする（この入力欄の本文は残すので、消えたら送り直せる）"
        case .forceSend: return "端末の入力欄を確かめないまま、この入力欄の本文を送る（入っていれば二重に送られる）"
        }
    }
}
