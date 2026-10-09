import SwiftUI
import MonitorKit

/// 別ウィンドウの中身: 1 つのルームの会話（メインの中央と同じ部品）。ルームが一覧から消えたら案内に替える。
struct RoomWindowView: View {
    @Bindable var model: ChatModel
    let token: UUID
    /// ウィンドウのタイトルをルーム名にする。
    let setTitle: (String) -> Void

    var body: some View {
        let room = model.detached.room(for: token).flatMap(model.room(id:))
        content(room)
            .frame(minWidth: ListPaneWidth.centerMinimum, maxWidth: .infinity, maxHeight: .infinity)
            .background(ChatTheme.background)
            .environment(\.colorScheme, ChatTheme.colorScheme(for: AppearanceSettings.shared.theme))
            .onChange(of: room?.sessionId, initial: true) { _, sessionId in
                model.transcripts.ensure(for: sessionId)
                model.markShownSeen()
            }
            // メインが隠れていると向こうの onChange が回らないことがあるので、こちらでも同じことをする（どちらも何度呼んでも同じ）。
            .onChange(of: model.store.feed.last?.id) { model.markShownSeen() }
            .onChange(of: model.store.connectionEpoch) { _, epoch in model.reconnectTranscripts(epoch: epoch) }
            .onChange(of: room?.name, initial: true) { _, name in
                if let name { setTitle(name) }
            }
            .alert("claude-deck", isPresented: Binding(get: { model.alerts.message != nil && model.alerts.target == token },
                                                       set: { if !$0 { model.alerts.message = nil } })) {
                Button("OK") { model.alerts.message = nil }
            } message: {
                Text(model.alerts.message ?? "")
            }
    }

    @ViewBuilder
    private func content(_ room: Room?) -> some View {
        if let room {
            ConversationView(model: model, room: room, inWindow: true)
                .id(room.id)
        } else if !model.store.connection.isConnected {
            CenterPlaceholder(symbol: "arrow.triangle.2.circlepath", text: "セッションの監視を始めています…")
        } else {
            // 見ていた画面が急に消えないよう、閉じるのは利用者に任せる。
            CenterPlaceholder(symbol: "bubble.left.and.exclamationmark.bubble.right", text: "このルームは閉じられました。")
        }
    }
}
