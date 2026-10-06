import SwiftUI
import MonitorKit

/// カードの見出し（アイコンと題）。
struct CardTitle: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(ChatTheme.permission)
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(ChatTheme.heading)
        }
    }
}

/// カード内の等幅の抜粋（確認するコマンド・plan の本文など）。
struct CardCode: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ChatTheme.mono)
            .foregroundStyle(ChatTheme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(ChatTheme.codeSurface))
    }
}

/// 控えめなボタン（拒否・キャンセル）。幅を省くと文字に合わせる。
struct CardButtonLabel: View {
    let title: String
    var width: CGFloat?

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatTheme.text)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.quietButton))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.quietButtonBorder))
    }
}

struct SendingIndicator: View {
    var body: some View {
        ProgressView().controlSize(.small)
        Text("送信中…").font(ChatTheme.caption).foregroundStyle(ChatTheme.secondary)
    }
}

extension View {
    /// 要対応のカードの枠（会話の末尾に amber で出す）。
    func cardFrame() -> some View {
        padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatTheme.cardBorder, lineWidth: 1.5))
    }

    /// Esc が claude の終了になるメニューで、送る前に確かめる。
    /// `presenting` は確認を開いた時のメニューで、送る時の照合にはそれを使う。
    func exitConfirmation<Menu>(presenting: Binding<Menu?>, onExit: @escaping (Menu) -> Void) -> some View {
        let isPresented = Binding(get: { presenting.wrappedValue != nil }, set: { if !$0 { presenting.wrappedValue = nil } })
        return confirmationDialog("claude を終了しますか？", isPresented: isPresented, presenting: presenting.wrappedValue) { menu in
            Button("終了する（Esc）", role: .destructive) { onExit(menu) }
            Button("やめる", role: .cancel) {}
        } message: { _ in
            Text("このメニューで Esc を押すと、取り消しではなく Claude Code の終了になります。")
        }
    }
}
