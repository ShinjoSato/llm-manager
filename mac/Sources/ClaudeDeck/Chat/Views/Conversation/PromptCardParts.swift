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
            .roundedSurface(9, fill: ChatTheme.quietButton, stroke: ChatTheme.quietButtonBorder)
    }
}

/// 選択肢を閉じる Esc のボタン。Esc が claude の終了になるメニューでは「終了」と出す。
struct CardEscapeButton: View {
    let exits: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardButtonLabel(title: exits ? "終了（Esc）" : "キャンセル（Esc）")
        }
        .buttonStyle(.plain)
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
            .roundedSurface(12, fill: ChatTheme.cardFill, stroke: ChatTheme.cardBorder, lineWidth: 1.5)
    }

    /// Esc が claude の終了になるメニューで送る前に確かめる。照合には確認を開いた時のメニュー（`presenting`）を使う。
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
