import SwiftUI
import MonitorKit

/// メイン画面: 一覧の切り替えバー（左端 48px）| ルームかディレクトリの一覧（既定 312px・境界のドラッグで変える）| 会話かディレクトリの詳細（中央）| 右パネル（任意。ステージパネルはここに差し込む）。
struct ChatRootView<Trailing: View>: View {
    @Bindable var model: ChatModel
    private let trailing: Trailing
    @State private var listPane = ListPaneLayout()

    init(model: ChatModel, @ViewBuilder trailing: () -> Trailing) {
        self.model = model
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            // 吹き出しを右の一覧の上に重ねるため手前に置く。
            ListModeBar(model: model).zIndex(1)
            Rectangle().fill(ChatTheme.border).frame(width: 1)
            ListPaneColumn(layout: listPane) { RoomListView(model: model) }
            ListPaneDivider(layout: listPane)
                .zIndex(1)
            center
                .frame(minWidth: ListPaneWidth.centerMinimum, maxWidth: .infinity, maxHeight: .infinity)
                // 観測しない箱に書き、ウィンドウの伸縮でこの画面全体を描き直させない。
                .onGeometryChange(for: Double.self) { $0.size.width } action: { listPane.centerWidth = $0 }
            trailing
        }
        .environment(listPane)
        .background(ChatTheme.background)
        .environment(\.colorScheme, ChatTheme.colorScheme(for: AppearanceSettings.shared.theme))
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.store.connectionEpoch) { model.transcripts.reconnected(selected: model.selectedRoom?.sessionId) }
        .onChange(of: model.selectedRoom?.sessionId, initial: true) { _, sessionId in
            model.transcripts.ensure(for: sessionId)
            model.markSelectedSeen()
        }
        .onChange(of: model.store.feed.last?.id) { model.markSelectedSeen() }
        .onChange(of: model.rooms.count) { selectFirstIfNeeded() }
        .onChange(of: model.firstVisibleRoom?.id) { selectFirstIfNeeded() }
        .alert("claude-deck", isPresented: Binding(get: { model.alerts.message != nil },
                                                   set: { if !$0 { model.alerts.message = nil } })) {
            Button("OK") { model.alerts.message = nil }
        } message: {
            Text(model.alerts.message ?? "")
        }
    }

    @ViewBuilder
    private var center: some View {
        if let selected = model.selectedDirectory {
            if let directory = selected.directory {
                DirectoryDetailView(model: model, directory: directory)
                    .id(selected.id)
            } else {
                DirectoryMissingView()
            }
        } else if let room = model.selectedRoom {
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

    /// 会話を出していて何も選んでいない時だけ先頭を選ぶ。選択中のルームが一覧から消えても別のルームへ移さない（戻ってきた時に書きかけごと続けられるように）。
    private func selectFirstIfNeeded() {
        if model.center == .room, model.selection == nil, let first = model.firstVisibleRoom {
            model.select(first.id)
        }
    }
}

extension ChatRootView where Trailing == EmptyView {
    init(model: ChatModel) {
        self.init(model: model) { EmptyView() }
    }
}

