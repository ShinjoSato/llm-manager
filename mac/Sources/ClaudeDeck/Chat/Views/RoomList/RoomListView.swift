import SwiftUI
import MonitorKit

/// 左カラム: ルーム一覧（検索・新規・接続状態・グループ）。
struct RoomListView: View {
    @Bindable var model: ChatModel
    @State private var showingLauncher = false

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            if !model.store.connection.isConnected { ConnectionNotice(connection: model.store.connection) }
            if let notice = HookServerNotice.text(for: model.store.serverState) { HookServerNotice(text: notice) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let items = model.listItems
                    if items.isEmpty { emptyState }
                    ForEach(items) { item in
                        switch item.kind {
                        case .header(let section, let collapsed):
                            ProjectSectionHeader(section: section, collapsed: collapsed,
                                                 onToggle: { model.toggleSection(section.id) },
                                                 onLaunch: section.project.map { project in { model.launch(project) } })
                                .padding(.top, 10)
                        case .row(let room, let last):
                            Button { model.select(room.id) } label: {
                                RoomRow(room: room, selected: model.selection == room.id)
                                    .equatable()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: room) }
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                            .padding(.bottom, last ? 4 : 0)
                            .background(SectionFrame(bottom: last))
                        case .empty:
                            Text("スレッドなし")
                                .font(ChatTheme.caption)
                                .foregroundStyle(ChatTheme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(SectionFrame(bottom: true))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(ChatTheme.sidebar)
    }

    private var header: some View {
        HStack {
            Text("ルーム")
                .font(ChatTheme.headline)
                .foregroundStyle(ChatTheme.heading)
            Spacer()
            Button { showingLauncher.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ChatTheme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ChatTheme.accent))
            }
            .buttonStyle(.plain)
            .help("プロジェクトを選んで Claude Code を起動（新しいルーム）")
            .popover(isPresented: $showingLauncher, arrowEdge: .bottom) {
                ProjectLauncher { project in
                    showingLauncher = false
                    model.launch(project)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ChatTheme.tertiary)
            TextField("", text: $model.query, prompt: Text("ルームを検索").foregroundStyle(ChatTheme.tertiary))
                .textFieldStyle(.plain)
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChatTheme.inputSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatTheme.inputBorder))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.query.isEmpty ? "ルームがありません" : "一致するルームがありません")
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.secondary)
            if model.query.isEmpty {
                Text("「+」からプロジェクトを選ぶと Claude Code が起動します。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func contextMenu(for room: Room) -> some View {
        if let session = room.hosted {
            Button(session.end == nil ? "ルームを閉じる（claude を終了）" : "ルームを閉じる") { model.close(session) }
        }
        Button("Finder で表示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: room.cwd)])
        }
    }
}
