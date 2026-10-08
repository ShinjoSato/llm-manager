import DeckCore
import SwiftUI

/// 入力欄。ホスト中のセッションは端末の入力欄へ、外部セッションは伝言として送る。
struct ComposerBar: View {
    @Bindable var model: AppModel
    let room: RemoteRoom
    @FocusState private var focused: Bool

    var body: some View {
        let relay = room.send.mode == .relay
        let reason = disabledReason
        let text = Binding(get: { model.drafts[room.id] ?? "" }, set: { model.drafts[room.id] = $0 })
        let sending = model.inFlight.contains(room.id)
        let canSend = reason == nil && !sending && !model.draftText(room.id).isEmpty
        VStack(alignment: .leading, spacing: 6) {
            if relay {
                HStack(spacing: 6) {
                    Text("伝言")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DeckTheme.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DeckTheme.permission))
                    Text("受け手には別セッションからのメッセージとして届きます")
                        .font(DeckTheme.caption)
                        .foregroundStyle(DeckTheme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.leading, 4)
            }
            if let reason, !text.wrappedValue.isEmpty {
                Text(reason).font(DeckTheme.caption).foregroundStyle(DeckTheme.permission).padding(.leading, 4)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: text, prompt: Text(reason ?? (relay ? "伝言を送信" : "メッセージを送信")).foregroundStyle(DeckTheme.tertiary),
                          axis: .vertical)
                    .font(DeckTheme.body)
                    .foregroundStyle(DeckTheme.text)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(reason != nil)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("composer")
                Button { model.send(room) } label: {
                    Group {
                        if sending {
                            ProgressView().tint(DeckTheme.onAccent)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundStyle(DeckTheme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(relay ? DeckTheme.permission : DeckTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend || sending ? 1 : 0.4)
                .padding(.bottom, 3)
                .accessibilityLabel(relay ? "伝言を送信" : "送信")
                .accessibilityIdentifier("send")
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 20).fill(DeckTheme.inputSurface))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(relay ? DeckTheme.permission.opacity(0.6) : DeckTheme.inputBorder,
                        style: StrokeStyle(lineWidth: 1, dash: relay ? [5, 4] : [])))
            .opacity(reason == nil ? 1 : 0.7)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(DeckTheme.background)
        .overlay(alignment: .top) { Rectangle().fill(DeckTheme.border).frame(height: 1) }
    }

    /// 送れない理由（mac が教えるもの・接続・終了）。
    private var disabledReason: String? {
        if !model.connection.isConnected { return "Mac につながっていません" }
        if let reason = room.send.disabledReason, !reason.isEmpty { return reason }
        if room.send.mode == .unknown { return "このルームには送れません" }
        return nil
    }
}
