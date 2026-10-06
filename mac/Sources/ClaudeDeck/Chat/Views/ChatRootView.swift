import AppKit
import SwiftUI
import MonitorKit

/// メイン画面: 一覧の切り替えバー（左端 48px）| ルームかディレクトリの一覧（既定 312px・境界のドラッグで変える）| 会話かディレクトリの詳細（中央）| 右パネル（任意。ステージパネルはここに差し込む）。
struct ChatRootView<Trailing: View>: View {
    @Bindable var model: ChatModel
    private let trailing: Trailing
    @AppStorage(ListPaneWidth.defaultsKey) private var listWidth = ListPaneWidth.standard
    @State private var centerWidth: Double = 0

    init(model: ChatModel, @ViewBuilder trailing: () -> Trailing) {
        self.model = model
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            // 吹き出しを右の一覧の上に重ねるため手前に置く。
            ListModeBar(model: model).zIndex(1)
            Rectangle().fill(ChatTheme.border).frame(width: 1)
            RoomListView(model: model)
                .frame(width: ListPaneWidth.clamped(listWidth))
            ListPaneDivider(width: $listWidth, centerWidth: centerWidth)
                .zIndex(1)
            center
                .frame(minWidth: ListPaneWidth.centerMinimum, maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { centerWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in centerWidth = width }
                    }
                }
            trailing
        }
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

/// 一覧と中央の境界。つかんで一覧の幅を変え、ダブルクリックで既定に戻す。
struct ListPaneDivider: View {
    @Binding var width: Double
    let centerWidth: Double
    @State private var drag: DragStart?
    @State private var hovering = false
    @State private var cursorPushed = false

    private struct DragStart {
        let width: Double
        let center: Double
    }

    /// 線は 1pt のまま、つかめる幅だけ広げる。
    private static let grabWidth: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(ChatTheme.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: Self.grabWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        updateCursor()
                    }
                    .gesture(dragGesture)
                    .onTapGesture(count: 2) { width = ListPaneWidth.standard }
                    .help("ドラッグで一覧の幅を変える（ダブルクリックで元の幅）")
            }
            .onDisappear {
                if cursorPushed { NSCursor.pop() }
                cursorPushed = false
            }
            .accessibilityElement()
            .accessibilityLabel("一覧の幅")
            .accessibilityValue("\(Int(ListPaneWidth.clamped(width))) ポイント")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                // 広げられる分はつかんだ時の中央の幅で決め、描き直しの遅れで中央の最小幅を割らないようにする。
                let start = drag ?? DragStart(width: ListPaneWidth.clamped(width), center: centerWidth)
                drag = start
                width = ListPaneWidth.dragged(start: start.width, translation: value.translation.width,
                                              current: start.width, centerWidth: start.center)
                updateCursor()
            }
            .onEnded { _ in
                drag = nil
                updateCursor()
            }
    }

    /// つかんでいる間はカーソルが境界から外れても左右の矢印のままにする。
    private func updateCursor() {
        let wants = hovering || drag != nil
        guard wants != cursorPushed else { return }
        if wants { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        cursorPushed = wants
    }
}
