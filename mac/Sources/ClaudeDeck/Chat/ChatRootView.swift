import SwiftUI
import MonitorKit

/// メイン画面: ルーム一覧（左 312px）| 会話（中央）| 右パネル（任意。ステージパネルはここに差し込む）。
struct ChatRootView<Trailing: View>: View {
    @Bindable var model: ChatModel
    private let trailing: Trailing

    init(model: ChatModel, @ViewBuilder trailing: () -> Trailing) {
        self.model = model
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            RoomListView(model: model)
                .frame(width: 312)
            Rectangle().fill(ChatTheme.border).frame(width: 1)
            center
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            trailing
        }
        .background(ChatTheme.background)
        .environment(\.colorScheme, .dark)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.store.connectionEpoch) { model.reconnected() }
        .onChange(of: model.selectedRoom?.sessionId, initial: true) { _, sessionId in
            model.ensureTranscript(for: sessionId)
            model.markSelectedSeen()
        }
        .onChange(of: model.store.feed.last?.id) { model.markSelectedSeen() }
        .onChange(of: model.rooms.count) { selectFirstIfNeeded() }
        .alert("claude-deck", isPresented: Binding(get: { model.alertMessage != nil },
                                                   set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var center: some View {
        if let room = model.selectedRoom {
            ConversationView(model: model, room: room)
                .id(room.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(ChatTheme.tertiary)
                Text("左のルームを選ぶか、「+」からプロジェクトを選んで Claude Code を起動します。")
                    .font(ChatTheme.body)
                    .foregroundStyle(ChatTheme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 何も選んでいない時だけ先頭を選ぶ。選択中のルームが一覧から消えても別のルームへ移さない（戻ってきた時に書きかけごと続けられるように）。
    private func selectFirstIfNeeded() {
        if model.selection == nil, let first = model.groupedRooms.first?.rooms.first {
            model.select(first.id)
        }
    }
}

extension ChatRootView where Trailing == EmptyView {
    init(model: ChatModel) {
        self.init(model: model) { EmptyView() }
    }
}
