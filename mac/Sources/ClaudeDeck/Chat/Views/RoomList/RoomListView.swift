import SwiftUI
import MonitorKit

/// 左カラム: 検索・新規・接続状態と、状態別のルームか登録ディレクトリの一覧。
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
                    switch model.listMode {
                    case .rooms: roomItems
                    case .directories: directoryItems
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
            Text(model.listMode.title)
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
            TextField("", text: $model.query, prompt: Text(model.listMode == .rooms ? "ルームを検索" : "名前・パスで絞り込む").foregroundStyle(ChatTheme.tertiary))
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

    @ViewBuilder
    private var roomItems: some View {
        let items = model.listItems
        if items.isEmpty { emptyState }
        ForEach(items) { item in
            switch item.kind {
            case .phase(let phase, let count):
                sectionTitle("\(phase.title)  \(count)")
            case .row(let room):
                row(room)
                    .padding(.vertical, 1)
            }
        }
    }

    @ViewBuilder
    private var directoryItems: some View {
        let entries = model.directoryEntries
        if entries.isEmpty { directoryEmptyState }
        ForEach(entries) { entry in
            switch entry {
            case .directory(let directory):
                Button { model.selectDirectory(directory.id) } label: {
                    DirectoryRow(directory: directory, selected: model.center == .directory(directory.id))
                        .equatable()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Claude Code を起動") { model.launch(directory.project) }
                    Button("Finder で表示") { model.editors.revealInFinder(directory.project.editorTarget) }
                }
                .padding(.vertical, 1)
            case .inactiveHeader(let count):
                sectionTitle("\(ProjectDirectories.inactiveTitle)  \(count)")
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ChatTheme.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var directoryEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.query.isEmpty ? "ディレクトリがありません" : "一致するディレクトリがありません")
                .font(ChatTheme.body)
                .foregroundStyle(ChatTheme.secondary)
            if model.query.isEmpty {
                Text("「+」の「フォルダを追加…」か設定画面で登録します。")
                    .font(ChatTheme.caption)
                    .foregroundStyle(ChatTheme.tertiary)
            }
        }
        .padding(16)
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

    private func row(_ room: Room) -> some View {
        Button { model.select(room.id) } label: {
            RoomRow(room: room, selected: model.center == .room && model.selection == room.id)
                .equatable()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu(for: room) }
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
